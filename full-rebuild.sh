#!/bin/bash
# full-rebuild.sh - Full environment destruction and rebuild
# This script automates the entire nuke and rebuild process

# Define colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m' # No Color

clear
echo -e "${RED}===============================================${NC}"
echo -e "${RED}     FULL INFRASTRUCTURE REBUILD PROCESS      ${NC}"
echo -e "${RED}===============================================${NC}"
echo -e "${YELLOW}This script will:${NC}"
echo -e "${YELLOW}1. Run nuke.sh to completely destroy your environment${NC}"
echo -e "${YELLOW}2. Run post-nuke.sh to restore credentials${NC}"
echo -e "${YELLOW}3. Initialize and apply Terraform to rebuild everything${NC}"
echo -e "${RED}This is a destructive process with no backups.${NC}"
echo

# Confirm execution
read -p "Are you sure you want to continue? (yes/no): " CONFIRM
if [[ "$CONFIRM" != "yes" ]]; then
    echo -e "${GREEN}Operation cancelled.${NC}"
    exit 0
fi

# Step 1: Run nuke.sh
echo -e "${BLUE}[1/4] Running nuke.sh...${NC}"
./nuke.sh

# Check if nuke.sh was successful
if [ $? -ne 0 ]; then
    echo -e "${RED}nuke.sh failed. Aborting process.${NC}"
    exit 1
fi

echo
echo -e "${BLUE}===============================================${NC}"
echo -e "${BLUE}Nuke complete. Starting restoration process...${NC}"
echo -e "${BLUE}===============================================${NC}"
sleep 2

# Step 2: Run post-nuke.sh
echo -e "${BLUE}[2/4] Running post-nuke.sh...${NC}"
./post-nuke.sh

# Check if post-nuke.sh was successful
if [ $? -ne 0 ]; then
    echo -e "${RED}post-nuke.sh failed. Aborting process.${NC}"
    exit 1
fi

echo
echo -e "${BLUE}===============================================${NC}"
echo -e "${BLUE}Credentials restored. Starting Terraform...${NC}"
echo -e "${BLUE}===============================================${NC}"
sleep 2

# Step 3: Run terraform init
echo -e "${BLUE}[3/4] Initializing Terraform...${NC}"
cd terraform
terraform init

# Check if terraform init was successful
if [ $? -ne 0 ]; then
    echo -e "${RED}terraform init failed. Aborting process.${NC}"
    exit 1
fi

echo
echo -e "${BLUE}===============================================${NC}"
echo -e "${BLUE}Terraform initialized. Starting rebuild...${NC}"
echo -e "${BLUE}===============================================${NC}"
sleep 2

# Step 4: Run terraform apply
echo -e "${BLUE}[4/4] Applying Terraform configuration...${NC}"
terraform apply -auto-approve

# Check if terraform apply was successful
if [ $? -ne 0 ]; then
    echo -e "${RED}terraform apply failed. Please check the logs.${NC}"
    exit 1
fi

# Return to project root
cd ..

echo
echo -e "${GREEN}===============================================${NC}"
echo -e "${GREEN}     FULL INFRASTRUCTURE REBUILD COMPLETE     ${NC}"
echo -e "${GREEN}===============================================${NC}"
echo -e "${GREEN}Your environment has been successfully:${NC}"
echo -e "${GREEN}1. Destroyed completely${NC}"
echo -e "${GREEN}2. Credentials have been restored${NC}"
echo -e "${GREEN}3. Infrastructure has been rebuilt${NC}"
echo -e "${GREEN}4. Application components have been redeployed${NC}"
echo
echo -e "${YELLOW}Your application should be available shortly at:${NC}"
echo -e "${YELLOW}$(cd terraform && terraform output | grep iot_application_url | cut -d '=' -f2 | xargs)${NC}"

# Optionally check pod status
echo
echo -e "${BLUE}Checking pod status...${NC}"
kubectl get pods -n iot-system || echo "Kubectl not configured yet. Please wait a few minutes."

exit 0