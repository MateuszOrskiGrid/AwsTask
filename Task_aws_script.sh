#!/bin/bash
set -e

REGION="eu-west-1"

# CIDR-y dla VPC i Subnetu
VPC_CIDR=""
SUBNET_CIDR=""

# Nazwa pary kluczy SSH do logowania na EC2
KEY_NAME=""

INSTANCE_TYPE="t2.micro"

# Nazwa repozytorium ECR
REPO_NAME="spring-petclinic"

echo "Wybieranie najnowszego obrazu Amazon Linux 2 (AMI)"
# Pobranie najnowszego obrazu Amazon Linux 2
AMI_ID=$(aws ec2 describe-images --region $REGION --owners amazon \
  --filters "Name=name,Values=amzn2-ami-kernel-5.10-hvm-2.0.*-x86_64-gp2" "Name=state,Values=available" \
  --query 'Images | sort_by(@, &CreationDate)[-1].ImageId' --output text)

# Pobranie ID konta AWS (potrzebne do ECR)
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# Adres URI dla repozytorium ECR
ECR_URI="$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com/$REPO_NAME"

# Tworzenie VPC
echo "Tworzenie VPC"
VPC_ID=$(aws ec2 create-vpc --cidr-block $VPC_CIDR --region $REGION --query 'Vpc.VpcId' --output text)

# Tworzenie Subnetu w obrębie VPC
echo "Tworzenie Subnetu"
SUBNET_ID=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block $SUBNET_CIDR --region $REGION --query 'Subnet.SubnetId' --output text)

# Tworzenie Internet Gateway i podłączanie do VPC
echo "Tworzenie i podłączanie Internet Gateway"
IGW_ID=$(aws ec2 create-internet-gateway --query 'InternetGateway.InternetGatewayId' --output text)
aws ec2 attach-internet-gateway --internet-gateway-id $IGW_ID --vpc-id $VPC_ID

# Tworzenie tablicy routingu i przypisanie do Subnetu
echo "Tworzenie Route Table i trasy do Internetu"
ROUTE_TABLE_ID=$(aws ec2 create-route-table --vpc-id $VPC_ID --query 'RouteTable.RouteTableId' --output text)
aws ec2 create-route --route-table-id $ROUTE_TABLE_ID --destination-cidr-block 0.0.0.0/0 --gateway-id $IGW_ID
aws ec2 associate-route-table --route-table-id $ROUTE_TABLE_ID --subnet-id $SUBNET_ID

# Tworzenie grupy zabezpieczeń i otwarcie portów 22 (SSH) i 8080 (aplikacja)
echo "Tworzenie Security Group i otwieranie portów"
SG_ID=$(aws ec2 create-security-group --group-name spring-sg --description "Allow 22 and 8080" --vpc-id $VPC_ID --query 'GroupId' --output text)
aws ec2 authorize-security-group-ingress --group-id $SG_ID --protocol tcp --port 22 --cidr 0.0.0.0/0
aws ec2 authorize-security-group-ingress --group-id $SG_ID --protocol tcp --port 8080 --cidr 0.0.0.0/0

# Tworzenie pary kluczy SSH i zapis prywatnego klucza do pliku lokalnego
echo "Tworzenie pary kluczy SSH"
aws ec2 create-key-pair --key-name $KEY_NAME --query 'KeyMaterial' --output text > $KEY_NAME.pem
chmod 400 $KEY_NAME.pem

# Tworzenie instancji EC2 z przypisanym publicznym adresem IP
echo "Tworzenie instancji EC2"
INSTANCE_ID=$(aws ec2 run-instances --image-id $AMI_ID --instance-type $INSTANCE_TYPE \
  --key-name $KEY_NAME --security-group-ids $SG_ID --subnet-id $SUBNET_ID \
  --associate-public-ip-address --region $REGION --query 'Instances[0].InstanceId' --output text)

# Czekanie aż instancja będzie gotowa
aws ec2 wait instance-running --instance-ids $INSTANCE_ID
PUBLIC_IP=$(aws ec2 describe-instances --instance-ids $INSTANCE_ID --region $REGION \
  --query "Reservations[0].Instances[0].PublicIpAddress" --output text)

# Tworzenie repozytorium ECR (jeśli nie istnieje)
echo "Tworzenie repozytorium ECR (jeśli nie istnieje)"
aws ecr create-repository --repository-name $REPO_NAME \
  --image-scanning-configuration scanOnPush=true --region $REGION --output text || true

# Logowanie się do ECR i wysyłanie obrazu Dockera
echo "Logowanie do ECR i wypychanie obrazu Docker"
aws ecr get-login-password --region $REGION | docker login --username AWS --password-stdin $ECR_URI
docker build -t $REPO_NAME .
docker tag $REPO_NAME:latest $ECR_URI:latest
docker push $ECR_URI:latest


# Połączenie SSH do EC2, instalacja Dockera, logowanie do ECR, pobranie obrazu, uruchomienie kontenera
echo "Instalacja Dockera na EC2 i uruchomienie kontenera"
ssh -o StrictHostKeyChecking=no -i $KEY_NAME.pem ec2-user@$PUBLIC_IP << EOF
  sudo yum update -y
  sudo amazon-linux-extras install docker -y
  sudo service docker start
  sudo usermod -aG docker ec2-user
  newgrp docker <<INNER
    aws ecr get-login-password --region $REGION | docker login --username AWS --password-stdin $ECR_URI
    docker pull $ECR_URI:latest
    docker run -d -p 8080:8080 $ECR_URI:latest
INNER
EOF

# Informacja o uruchomionej aplikacji
echo "Aplikacja została uruchomiona pod adresem: http://$PUBLIC_IP:8080"

# Oczekiwanie na potwierdzenie przed usunięciem zasobów
read -p "Naciśnij Enter, aby usunąć wszystkie zasoby AWS..."

# Usuwanie instancji EC2
echo "Usuwanie instancji EC2"
aws ec2 terminate-instances --instance-ids $INSTANCE_ID --region $REGION
aws ec2 wait instance-terminated --instance-ids $INSTANCE_ID --region $REGION

# Usuwanie repozytorium ECR
echo "Usuwanie repozytorium ECR"
aws ecr delete-repository --repository-name $REPO_NAME --force --region $REGION

# Usuwanie Security Group
echo "Usuwanie Security Group"
aws ec2 delete-security-group --group-id $SG_ID --region $REGION

# Usuwanie Internet Gateway i VPC
echo "Usuwanie Internet Gateway i VPC"
aws ec2 detach-internet-gateway --internet-gateway-id $IGW_ID --vpc-id $VPC_ID
aws ec2 delete-internet-gateway --internet-gateway-id $IGW_ID --region $REGION
aws ec2 delete-subnet --subnet-id $SUBNET_ID --region $REGION
aws ec2 delete-route-table --route-table-id $ROUTE_TABLE_ID --region $REGION
aws ec2 delete-vpc --vpc-id $VPC_ID --region $REGION

# Usuwanie pary kluczy i lokalnego pliku .pem
echo "Usuwanie pary kluczy i pliku lokalnego"
aws ec2 delete-key-pair --key-name $KEY_NAME --region $REGION
rm -f $KEY_NAME.pem

echo "Wszystkie zasoby zostały usunięte"