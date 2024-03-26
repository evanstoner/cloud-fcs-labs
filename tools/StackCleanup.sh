#--------------------------#                      
#  FCS Lab Cleanup Script  #
#--------------------------#  

read -p "Are you deleting K8s protection only, FalconStack only, or FalconStack AND InfraStack resources? [k8s|falcon|all]: " CleanupPrompt
   CleanupPrompt=${CleanupPrompt:=falcon}
   if [ $CleanupPrompt = k8s ]; then

#---------------#
#  K8s cleanup  # 
#---------------#

## Delete Falcon protection components to reset the cluster for re-running deployFalcon.
# note: deleting the falcon-operator (below) hangs. You can just leave it if you prefer.
kubectl delete -f https://github.com/CrowdStrike/falcon-operator/releases/latest/download/falcon-operator.yaml --force
kubectl delete daemonset falcon-node-sensor -n falcon-system

# # Delete k8s ingress and AWS load balancer controller to simplify stack cleanup
# kubectl delete ingress webapp-ingress
# helm uninstall aws-load-balancer-controller -n kube-system
# helm repo remove eks
# helm uninstall falcon-kac -n falcon-kac
# kubectl delete sa aws-load-balancer-controller -n kube-system
# kubectl delete deployment webapp

   
   elif [ $CleanupPrompt = false ]; then
      echo "Exiting cleanup"
      exit 1
   else
      echo "Not a valid response, exiting cleanup"
      exit 1
   fi
echo "Deleting InfraStack resources"
#------------------------#                      
#  deployFalcon cleanup  #
#------------------------#                    

# set environment variables
AWS_REGION='us-east-1'

EnvHash=$(aws ssm get-parameter --name "psEnvHash" --query 'Parameter.Value' --output text --region=$AWS_REGION)
S3Bucket=$(aws ssm get-parameter --name "psS3Bucket" --query 'Parameter.Value' --output text --region=$AWS_REGION)
FalconStack=$(aws ssm get-parameter --name "psFalconStack-$EnvHash" --query 'Parameter.Value' --output text --region=$AWS_REGION)
CodePipelineBucket=$(aws ssm get-parameter --name "psCodePipelineBucket-$EnvHash" --query 'Parameter.Value' --output text --region=$AWS_REGION)
TrailBucket=$(aws ssm get-parameter --name "psTrailBucket-$EnvHash" --query 'Parameter.Value' --output text --region=$AWS_REGION)

## Run from the Bastion Host! 
## You can run the entire script at once if you want to delete all FCS-lab stacks, or you can run deployFalcon section separately.

# Delete ECR repositories to prevent a CloudFormation delete-stack race condition error
aws ecr delete-repository --repository-name falcon-kac --force
aws ecr delete-repository --repository-name falcon-sensor --force

# Replace with deletion of ELBv and Target groups
loadBalancerArn=$(aws elbv2 describe-load-balancers --query 'LoadBalancers[].LoadBalancerArn[]' --output text | grep k8s-default-webappin)
aws elbv2 delete-load-balancer --load-balancer-arn $loadBalancerArn
sleep 10
targetGroupArn=$(aws elbv2 describe-target-groups --query 'TargetGroups[].TargetGroupArn[]' --output text | grep k8s-default-webapp)
aws elbv2 delete-target-group --target-group-arn $targetGroupArn

# StackSet instance deletion
accountId=$(aws sts get-caller-identity --query Account --output text)
aws cloudformation delete-stack-instances --stack-set-name CrowdStrike-Horizon-EB-Stackset --regions us-east-1 --no-retain-stacks --accounts ${accountId}

# S3 bucket empyting and deletion. 
aws s3 rm --recursive --quiet s3://$CodePipelineBucket
echo "Bucket $CodePipelineBucket emptied\!"

aws s3 rm --recursive --quiet s3://$TrailBucket
aws s3 rb --force s3://$TrailBucket 
echo "Bucket $TrailBucket deleted\!"

# Time for the CSPM StackSet instance to delete
sleep 60

# Delete deployFalcon CloudFormation stacks
aws cloudformation delete-stack --stack-name $FalconStack

#-----------------------#                       
#  deployInfra cleanup  #
#-----------------------# 

## If you run this section separately (after running deployFalcon stack deletion), you can run from AWS CloudShell 

# set environment variables
AWS_REGION='us-east-1'

EnvHash=$(aws ssm get-parameter --name "psEnvHash" --query 'Parameter.Value' --output text --region=$AWS_REGION)
S3Bucket=$(aws ssm get-parameter --name "psS3Bucket" --query 'Parameter.Value' --output text --region=$AWS_REGION)
LoggingBucket=$(aws ssm get-parameter --name "psLoggingBucket-$EnvHash" --query 'Parameter.Value' --output text --region=$AWS_REGION)
InfraStack=$(aws ssm get-parameter --name "psInfraStack-$EnvHash" --query 'Parameter.Value' --output text --region=$AWS_REGION)

# Delete eksctl stacks 
aws cloudformation delete-stack --stack-name eksctl-fcs-lab-addon-iamserviceaccount-kube-system-aws-load-balancer-controller
aws cloudformation delete-stack --stack-name eksctl-fcs-lab-addon-iamserviceaccount-default-pod-s3-access
aws cloudformation delete-stack --stack-name eksctl-fcs-lab-nodegroup-ng-1
aws cloudformation delete-stack --stack-name eksctl-fcs-lab-addon-iamserviceaccount-kube-system-aws-node

# S3 bucket empyting and deletion. 
aws s3 rm --recursive --quiet s3://$LoggingBucket
aws s3 rb --force s3://$LoggingBucket
echo "Bucket $LoggingBucket deleted\!"

# After cluster nodegroup stack deletes, delete the cluster
sleep 250
aws cloudformation delete-stack --stack-name "eksctl-fcs-lab-cluster"

# Delete deployInfra CloudFormation stacks based on stackname stored parameter
aws cloudformation delete-stack --stack-name $InfraStack

# Try EKS cluster delete again
sleep 150
aws cloudformation delete-stack --stack-name "eksctl-fcs-lab-cluster"

# S3 bucket empyting and deletion. 
aws s3 rm --recursive --quiet s3://$S3Bucket
aws s3 rb --force s3://$S3Bucket
echo "Bucket $S3Bucket deleted\!"