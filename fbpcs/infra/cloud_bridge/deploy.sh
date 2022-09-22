#!/bin/bash
# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.

set -e
# shellcheck disable=SC1091
# shellcheck disable=SC1090
source "$(dirname "$(realpath "$0")")/util.sh"
usage() {
    echo "Usage: deploy.sh <deploy|undeploy>
        [ -r, --region | AWS region, e.g. us-west-2 ]
        [ -t, --tag | Tag that going to use as the PCE id and appended after the resource name]
        [ -a, --account_id | Your AWS account ID]
        [ -p, --publisher_account_id | Publisher's AWS account ID]
        [ -v, --publisher_vpc_id | Publisher's VPC Id]
        [ -s, --config_storage_bucket | optional. S3 bucket name for storing configs: tfstate/lambda function]
        [ -d, --data_storage_bucket | optional. S3 bucket name for storing lambda processed results]
        [ -b, --build_semi_automated_data_pipeline | optional. whether to build semi automated (manual upload) data pipeline ]"
    exit 1
}

if [ $# -eq 0 ]; then
    usage
fi

undeploy=false
build_semi_automated_data_pipeline=false

case "$1" in
    deploy) ;;
    undeploy) undeploy=true ;;
    *) usage ;;
esac
shift

while [ $# -gt 0 ]; do
    second_shift_flag=true
    case "$1" in
        -r|--region) region="$2" ;;
        -t|--tag) pce_id="$2" ;;
        -a|--account_id) aws_account_id="$2" ;;
        -p|--publisher_account_id) publisher_aws_account_id="$2" ;;
        -v|--publisher_vpc_id) publisher_vpc_id="$2" ;;
        -s|--config_storage_bucket) s3_bucket_for_storage="$2" ;;
        -d|--data_storage_bucket) s3_bucket_data_pipeline="$2" ;;
        -b|--build_semi_automated_data_pipeline) build_semi_automated_data_pipeline=true second_shift_flag=false ;;
        *) usage ;;
    esac
    shift
    test "$second_shift_flag" == "true" && shift
done

#### Terraform Logs
if [ -z ${TF_LOG+x} ]; then
    echo "Terraform Detailed Error Logging Disabled"
else
    echo "Terraform Log Level: $TF_LOG"
    echo "Terraform Log File: $TF_LOG_PATH"
    echo "Terraform Log File: $TF_LOG_STREAMING"
    echo
fi



undeploy_aws_resources() {
    # validate all the inputs
    log_streaming_data "starting to undeploy resources"
    input_validation "$region" "$pce_id" "$aws_account_id" "$publisher_aws_account_id" "$publisher_vpc_id" "$s3_bucket_for_storage" "$s3_bucket_data_pipeline" "$build_semi_automated_data_pipeline" "$undeploy"
    echo "Start undeploying AWS resource under PCE_shared..."
    echo "########################Check tfstate files########################"
    check_s3_object_exist "$s3_bucket_for_storage" "tfstate/pce_shared$tag_postfix.tfstate" "$aws_account_id"
    echo "Related tfstate file exists. Continue..."
    echo "######################## Initializing terraform working directory before deleting resources ########################"
    log_streaming_data "starting to undeploy core infra resources"
    cd /terraform_deployment/terraform_scripts/common/pce_shared
    terraform init -reconfigure \
        -backend-config "bucket=$s3_bucket_for_storage" \
        -backend-config "region=$region" \
        -backend-config "key=tfstate/pce_shared$tag_postfix.tfstate"
    echo "######################## Initializing terraform working directory completed!! ########################"
    echo "######################## Undeploying AWS resources ########################"
    terraform destroy \
        -auto-approve \
        -var "aws_region=$region" \
        -var "tag_postfix=$tag_postfix" \
        -var "aws_account_id=$aws_account_id" \
        -var "pce_id=$pce_id"
    echo "Finished undeploying AWS resources under PCE_shared."
    echo "Start undeploying AWS resource under PCE..."
    echo "########################Check tfstate files########################"
    check_s3_object_exist "$s3_bucket_for_storage" "tfstate/pce$tag_postfix.tfstate" "$aws_account_id"
    echo "Related tfstate file exists. Continue..."
    echo "######################## Initializing terraform working directory before deleting resources ########################"
    cd /terraform_deployment/terraform_scripts/common/pce
    terraform init -reconfigure \
        -backend-config "bucket=$s3_bucket_for_storage" \
        -backend-config "region=$region" \
        -backend-config "key=tfstate/pce$tag_postfix.tfstate"
    echo "######################## Initializing terraform working directory completed ########################"
    echo "########################Deleting########################"

    terraform destroy \
        -auto-approve \
        -var "aws_region=$region" \
        -var "tag_postfix=$tag_postfix" \
        -var "pce_id=$pce_id"
    echo "Finished undeploying AWS resource under PCE."
    echo "Start undeploying AWS resource under VPC peering..."
    log_streaming_data "starting to undeploy VPC related resources "
    echo "########################Check tfstate files########################"
    check_s3_object_exist "$s3_bucket_for_storage" "tfstate/vpcpeering$tag_postfix.tfstate" "$aws_account_id"
    echo "Related tfstate file exists. Continue..."
    echo "######################## Initializing terraform working directory before deleting resources ########################"
    cd /terraform_deployment/terraform_scripts/partner/vpc_peering
    terraform init -reconfigure \
        -backend-config "bucket=$s3_bucket_for_storage" \
        -backend-config "region=$region" \
        -backend-config "key=tfstate/vpcpeering$tag_postfix.tfstate"
    echo "######################## Initializing terraform working directory completed ########################"
    echo "########################Deleting########################"
    terraform destroy \
        -auto-approve \
        -var "aws_region=$region" \
        -var "tag_postfix=$tag_postfix" \
        -var "pce_id=$pce_id"

    echo "Finished undeploying AWS resource under VPC peering."
    echo "Start undeploying AWS resource under Data Ingestion..."
    echo "########################Check tfstate files########################"
    check_s3_object_exist "$s3_bucket_for_storage" "tfstate/data_ingestion$tag_postfix.tfstate" "$aws_account_id"
    echo "Related tfstate files exists. Continue..."
    echo "########################Deleting########################"
    log_streaming_data "starting to undeploy data ingestion resources "
    cd /terraform_deployment/terraform_scripts/data_ingestion
    echo "######################## Initializing terraform working directory before deleting resources ########################"
    terraform init -reconfigure \
        -backend-config "bucket=$s3_bucket_for_storage" \
        -backend-config "region=$region" \
        -backend-config "key=tfstate/data_ingestion$tag_postfix.tfstate"
    echo "######################## Initializing terraform working directory completed ########################"
    # Exclude the s3 bucket because it can not be deleted if it's not empty
    terraform state rm aws_s3_bucket.bucket || true
    echo "########################Deleting########################"
    echo "########################Ensuring Glue job $glue_crawler_name is stopped########################"
    stopGlueCrawlerJob "$glue_crawler_name" "$region"
    terraform destroy \
        -auto-approve \
        -var "region=$region" \
        -var "tag_postfix=$tag_postfix" \
        -var "aws_account_id=$aws_account_id" \
        -var "data_processing_lambda_s3_bucket=$s3_bucket_for_storage" \
        -var "data_processing_lambda_s3_key=lambda.zip" \
        -var "data_upload_key_path=$data_upload_key_path" \
        -var "query_results_key_path=$query_results_key_path"
    echo "########################Deletion completed########################"

    if "$build_semi_automated_data_pipeline"
    then
        echo "Undeploy Semi automated data_pipeline..."
        log_streaming_data "starting to undeploy data_pipeline "
        check_s3_object_exist "$s3_bucket_for_storage" "tfstate/glue_etl$tag_postfix.tfstate" "$aws_account_id"
        echo "Semi automated data_pipeline tfstate file exists. Continue..."
        cd /terraform_deployment/terraform_scripts/semi_automated_data_ingestion
        # lambda_trigger.py needs to be copied here in case a deploy was not previously run in the container
        cp template/lambda_trigger.py .
        terraform init -reconfigure \
        -backend-config "bucket=$s3_bucket_for_storage" \
        -backend-config "region=$region" \
        -backend-config "key=tfstate/glue_etl$tag_postfix.tfstate"

        # Exclude the s3 bucket because it can not be deleted if it's not empty
        terraform state rm aws_s3_bucket.bucket || true
        terraform destroy \
            -auto-approve \
            -var "region=$region" \
            -var "tag_postfix=$tag_postfix" \
            -var "aws_account_id=$aws_account_id" \
            -var "data_upload_key_path=$data_upload_key_path"
    fi
    echo "######################## Undeploy resources policy ########################"
    log_streaming_data "Undeploying resources policies..."
    cd /terraform_deployment
    python3 cli.py destroy aws \
        --delete_iam_policy \
        --policy_name "$policy_name"
    echo "######################## Finished undeploy resources policy ########################"

    log_streaming_data "finished undeploying all AWS resources "
    echo "Finished destroying all AWS resources, except for:"
    echo "  # S3 storage bucket ${s3_bucket_for_storage}"
    echo "  # S3 data bucket ${s3_bucket_data_pipeline}"
    echo "The following resources may have been deleted:"
    echo "  # IAM policy ${policy_name} (it will be deleted only if it is not attached to any users)"
    log_streaming_data "undeployment process finished"
}


deploy_aws_resources() {
    # first log, making sure the file is re-written fresh
    log_streaming_data "starting to deploy resources..."
    log_streaming_data "validating inputs..."
    # validate all the inputs
    input_validation "$region" "$pce_id" "$aws_account_id" "$publisher_aws_account_id" "$publisher_vpc_id" "$s3_bucket_for_storage" "$s3_bucket_data_pipeline" "$build_semi_automated_data_pipeline" "$undeploy"
    #clean up previously generated resources if any
    cleanup_generated_resources
    # Create the S3 bucket (to store config files) if it doesn't exist
    log_streaming_data "creating s3 config bucket, if it does not exist"
    validate_or_create_s3_bucket "$s3_bucket_for_storage" "$region" "$aws_account_id"
    # Create the S3 data bucket if it doesn't exist
    log_streaming_data "creating s3 data bucket, if it does not exist"
    validate_or_create_s3_bucket "$s3_bucket_data_pipeline" "$region" "$aws_account_id"
    # Deploy PCE Terraform scripts
    onedocker_ecs_container_image='539290649537.dkr.ecr.us-west-2.amazonaws.com/one-docker-prod:latest'
    publisher_vpc_cidr='10.0.0.0/16'

    echo "########################Initializing terraform working directory########################"
    cd /terraform_deployment/terraform_scripts/common/pce_shared
    terraform init -reconfigure \
        -backend-config "bucket=$s3_bucket_for_storage" \
        -backend-config "region=$region" \
        -backend-config "key=tfstate/pce_shared$tag_postfix.tfstate"
    echo "########################Initializing terraform working directory completed ########################"
    echo "######################## Deploy PCE SHARED Terraform scripts started ########################"
    terraform apply \
        -auto-approve \
        -var "aws_region=$region" \
        -var "tag_postfix=$tag_postfix" \
        -var "aws_account_id=$aws_account_id" \
        -var "onedocker_ecs_container_image=$onedocker_ecs_container_image" \
        -var "pce_id=$pce_id"
    echo "######################## Deploy PCE SHARED Terraform scripts completed ########################"
    # Store the outputs into variables
    onedocker_task_definition_family=$(terraform output onedocker_task_definition_family | tr -d '"')
    onedocker_task_definition_revision=$(terraform output onedocker_task_definition_revision | tr -d '"')
    onedocker_task_definition_container_definiton_name=$(terraform output onedocker_task_definition_container_definitons | jq 'fromjson | .[].name' | tr -d '"')
    ecs_task_execution_role_name=$(terraform output ecs_task_execution_role_name | tr -d '"')

    cd /terraform_deployment/terraform_scripts/common/pce
    echo "########################Initializing terraform working directory########################"
    log_streaming_data "creating core infra resources..."
    terraform init -reconfigure \
        -backend-config "bucket=$s3_bucket_for_storage" \
        -backend-config "region=$region" \
        -backend-config "key=tfstate/pce$tag_postfix.tfstate"
    echo "######################## Initializing terraform working directory completed ########################"
    echo "######################## Deploy PCE Terraform scripts started ########################"
    terraform apply \
        -auto-approve \
        -var "aws_region=$region" \
        -var "tag_postfix=$tag_postfix" \
        -var "otherparty_vpc_cidr=$publisher_vpc_cidr" \
        -var "pce_id=$pce_id"
    echo "######################## Deploy PCE Terraform scripts completed ########################"
    # Store the outputs into variables
    vpc_id=$(terraform output vpc_id | tr -d '"' )
    subnet_ids=$(terraform output subnets | tr -d '""[]\ \n')
    route_table_id=$(terraform output route_table_id | tr -d '"')
    aws_ecs_cluster_name=$(terraform output aws_ecs_cluster_name | tr -d '"')
    log_streaming_data "establishing vpc peering connection..."
    # Issue VPC Peering Connection to Publisher's VPC and add a route to the route table
    echo "########################Issue VPC Peering connection to Publisher's VPC########################"
    cd /terraform_deployment/terraform_scripts/partner/vpc_peering
    echo "######################## Initializing terraform working directory started ########################"
    terraform init -reconfigure \
        -backend-config "bucket=$s3_bucket_for_storage" \
        -backend-config "region=$region" \
        -backend-config "key=tfstate/vpcpeering$tag_postfix.tfstate"
    echo "######################## Initializing terraform working directory completed ########################"
    echo "######################## Deploy VPC Peering Terraform scripts started ########################"
    terraform apply \
        -auto-approve \
        -var "aws_region=$region" \
        -var "tag_postfix=$tag_postfix" \
        -var "peer_aws_account_id=$publisher_aws_account_id" \
        -var "peer_vpc_id=$publisher_vpc_id" \
        -var "vpc_id=$vpc_id" \
        -var "route_table_id=$route_table_id" \
        -var "destination_cidr_block=$publisher_vpc_cidr" \
        -var "pce_id=$pce_id"
    echo "######################## Deploy VPC Peering Terraform scripts completed ########################"

    # Store the outputs into variables
    vpc_peering_connection_id=$(terraform output vpc_peering_connection_id | tr -d '"' )
    echo "VPC peering connection has been created. ID: $vpc_peering_connection_id"

    # Configure Data Ingestion Pipeline from CB to S3
    echo "########################Configure Data Ingestion Pipeline from CB to S3########################"
    cd /terraform_deployment/terraform_scripts/data_ingestion
    echo "######################## Initializing terraform working directory started ########################"
    log_streaming_data "configuring data ingestion pipeline..."
    terraform init -reconfigure \
        -backend-config "bucket=$s3_bucket_for_storage" \
        -backend-config "region=$region" \
        -backend-config "key=tfstate/data_ingestion$tag_postfix.tfstate"
    echo "######################## Initializing terraform working directory completed ########################"
    echo "######################## Deploy Data Ingestion Terraform scripts started ########################"
    terraform apply \
        -auto-approve \
        -var "region=$region" \
        -var "tag_postfix=$tag_postfix" \
        -var "aws_account_id=$aws_account_id" \
        -var "data_processing_output_bucket=$s3_bucket_data_pipeline" \
        -var "data_processing_output_bucket_arn=$data_bucket_arn" \
        -var "data_ingestion_lambda_name=$data_ingestion_lambda_name" \
        -var "data_processing_lambda_s3_bucket=$s3_bucket_for_storage" \
        -var "data_processing_lambda_s3_key=lambda.zip" \
        -var "data_upload_key_path=$data_upload_key_path" \
        -var "query_results_key_path=$query_results_key_path"
    echo "######################## Deploy Data Ingestion Terraform scripts completed ########################"
    # store the outputs from data ingestion pipeline output into variables
    firehose_stream_name=$(terraform output firehose_stream_name | tr -d '"')
    events_data_crawler_arn=$(terraform output events_data_crawler_arn | tr -d '"')

    if "$build_semi_automated_data_pipeline"
    then
        echo "########################Configure Semi-automated Data Ingestion Pipeline from CB to S3########################"
        log_streaming_data "configuring semi-automated data ingestion pipeline from CAPI-G to s3"
        # configure semi-automated data ingestion pipeline, if true
        cd /terraform_deployment/terraform_scripts/semi_automated_data_ingestion
        # copy the lambda_trigger.py template to the local directory
        cp template/lambda_trigger.py .
        echo "Updating trigger function configurations..."
        sed -i "s/glueJobName = \"TO_BE_UPDATED_DURING_DEPLOYMENT\"/glueJobName = \"glue-ETL$tag_postfix\"/g" lambda_trigger.py
        sed -i "s~s3_write_path = \"TO_BE_UPDATED_DURING_DEPLOYMENT\"~s3_write_path = \"$s3_bucket_data_pipeline/events_data/\"~g" lambda_trigger.py

        echo "######################## Initializing terraform working directory started ########################"
        terraform init -reconfigure \
            -backend-config "bucket=$s3_bucket_for_storage" \
            -backend-config "region=$region" \
            -backend-config "key=tfstate/glue_etl$tag_postfix.tfstate"
        echo "######################## Initializing terraform working directory completed ########################"
        echo "######################## Deploy Semi-automated Data Ingestion Terraform scripts started ########################"
        terraform apply \
            -auto-approve \
            -var "region=$region" \
            -var "tag_postfix=$tag_postfix" \
            -var "aws_account_id=$aws_account_id" \
            -var "lambda_trigger_s3_key=lambda_trigger.zip" \
            -var "app_data_input_bucket=$s3_bucket_data_pipeline" \
            -var "app_data_input_bucket_id=$s3_bucket_data_pipeline" \
            -var "app_data_input_bucket_arn=$data_bucket_arn" \
            -var "data_upload_key_path=$data_upload_key_path"
        echo "######################## Deploy Semi-automated Data Ingestion Terraform scripts completed ########################"
    fi

    echo "########################Finished AWS Infrastructure Deployment########################"
    log_streaming_data "finished deploying resources..."
    echo "########################Start populating config.yml ########################"
    log_streaming_data "starting to populate config.yml"
    cd /terraform_deployment
    sed -i "s/region: .*/region: $region/g" config.yml
    echo "Populated region with value $region"

    sed -i "s/cluster: .*/cluster: $aws_ecs_cluster_name/g" config.yml
    echo "Populated cluster with value $aws_ecs_cluster_name"

    sed -i "s/subnets: .*/subnets: [${subnet_ids}]/g" config.yml
    echo "Populated subnets with value '[${subnet_ids}]'"

    onedocker_task_definition=$onedocker_task_definition_family:$onedocker_task_definition_revision#$onedocker_task_definition_container_definiton_name
    sed -i "s/task_definition: .*/task_definition: $onedocker_task_definition/g" config.yml
    echo "Populated Onedocker - task_definition with value $onedocker_task_definition"

    echo "########################Upload config.ymls to S3########################"
    log_streaming_data "start to upload config.yml"
    cd /terraform_deployment
    aws s3api put-object --bucket "$s3_bucket_for_storage" --key "config.yml" --body ./config.yml
    echo "########################Finished upload config.ymls to S3########################"

    echo "######################## Deploy resources policy ########################"
    log_streaming_data "deploying resources policies..."
    cd /terraform_deployment
    python3 cli.py create aws \
        --add_iam_policy \
        --policy_name "$policy_name" \
        --region "$region" \
        --firehose_stream_name "$firehose_stream_name" \
        --data_ingestion_lambda_name "$data_ingestion_lambda_name" \
        --data_bucket_name "$s3_bucket_data_pipeline" \
        --config_bucket_name "$s3_bucket_for_storage" \
        --database_name "$database_name" \
        --table_name "$table_name" \
        --cluster_name "$aws_ecs_cluster_name" \
        --ecs_task_execution_role_name "$ecs_task_execution_role_name" \
        --events_data_crawler_arn "$events_data_crawler_arn"
    echo "######################## Finished deploy resources policy ########################"
    log_streaming_data "validating generated resoureces and policies..."
    # validate generated resources through PCE validator
    validateDeploymentResources "$region" "$pce_id"

}


##########################################
# Main
##########################################
tag_postfix="-${pce_id}"

# if no input for bucket names, then go by default

if [ -z ${s3_bucket_for_storage+x} ]
then
    # s3_bucket_for_storage is unset
    s3_bucket_for_storage="fb-pc-config$tag_postfix"
else
    # s3_bucket_for_storage is set, but add tags to it
    s3_bucket_for_storage="$s3_bucket_for_storage$tag_postfix"
fi

if [ -z ${s3_bucket_data_pipeline+x} ]
then
    # s3_bucket_data_pipeline is unset
    s3_bucket_data_pipeline="fb-pc-data$tag_postfix"
else
    # s3_bucket_data_pipeline is set, but add tags to it
    s3_bucket_data_pipeline="$s3_bucket_data_pipeline$tag_postfix"
fi

data_bucket_arn="arn:aws:s3:::${s3_bucket_data_pipeline}"
policy_name="fb-pc-policy${tag_postfix}"
database_name="mpc-events-db${tag_postfix}"
glue_crawler_name="mpc-events-crawler${tag_postfix}"
table_name=${s3_bucket_data_pipeline//-/_}
data_upload_key_path="semi-automated-data-ingestion"
query_results_key_path="query-results"
data_ingestion_lambda_name="cb-data-ingestion-stream-processor${tag_postfix}"

if "$undeploy"
then
    echo "Undeploying the AWS resources..."
    undeploy_aws_resources
else
    echo "Deploying AWS resources..."
    deploy_aws_resources
fi
exit 0
