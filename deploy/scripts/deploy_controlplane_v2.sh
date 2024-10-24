#!/usr/bin/env bash

# Fail on any error, undefined variable, or pipeline failure
set -euo pipefail

# Enable debug mode if DEBUG is set to 'true'
[[ "${DEBUG:-false}" == 'true' ]] && set -x

# Constants
script_directory="$(dirname "$(realpath "${BASH_SOURCE[0]}")")"
readonly script_directory

SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_NAME

CONFIG_REPO_PATH="${script_directory}/.."
CONFIG_DIR="${CONFIG_REPO_PATH}/.sap_deployment_automation"
readonly CONFIG_DIR

if [[  -f /etc/profile.d/deploy_server.sh ]]; then
  path=$(grep -m 1 "export PATH=" /etc/profile.d/deploy_server.sh  | awk -F'=' '{print $2}' | xargs)
  export PATH=$path
fi

print_banner() {
    local title="$1"
    local message="$2"
    local type="${3:-info}"

    local boldred="\e[1;31m"
    local cyan="\e[1;36m"
    local green="\e[1;32m"
    local reset="\e[0m"

    local color
    case "$type" in
        error)
            color="$boldred"
            ;;
        success)
            color="$green"
            ;;
        info)
            color="$cyan"
            ;;
        *)
            color="$cyan"
            ;;
    esac

    local width=80
    local padding_title=$(( (width - ${#title}) / 2 ))
    local padding_message=$(( (width - ${#message}) / 2 ))

    local centered_title
    local centered_message
    centered_title=$(printf "%*s%s%*s" $padding_title "" "$title" $padding_title "")
    centered_message=$(printf "%*s%s%*s" $padding_message "" "$message" $padding_message "")

    echo ""
    echo -e "${color}"
    echo "#########################################################################################"
    echo "#                                                                                       #"
    echo -e "#${centered_title}#"
    echo "#                                                                                       #"
    echo -e "#${centered_message}#"
    echo "#                                                                                       #"
    echo "#########################################################################################"
    echo -e "${reset}"
    echo ""
}

# Function to source helper scripts
source_helper_scripts() {
  local -a helper_scripts=("$@")
  for script in "${helper_scripts[@]}"; do
      if [[ -f "$script" ]]; then
          # shellcheck source=/dev/null
          source "$script"
      else
          echo "Helper script not found: $script"
          exit 1
      fi
  done
}

# example: log "Starting remote copy for ${server}"
log() {
  echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')]: $*" >&2
}

# Function to handle cleanup on exit
cleanup() {
  local exit_code=$?

  log "deploy controlplane completed with exit code $exit_code"

  # Add any cleanup tasks here
  exit $exit_code
}
trap cleanup EXIT

# Main function
main() {
  local deployer_parameter_file=""
  local library_parameter_file=""
  local subscription=""
  local client_id=""
  local spn_secret=""
  local tenant_id=""
  local remote_state_sa=""
  local keyvault=""
  local force=0
  local recover=0
  local ado_flag=""
  local deploy_using_msi_only=0
  local approve=""

  if [[  -f /etc/profile.d/deploy_server.sh ]]; then
  path=$(grep -m 1 "export PATH=" /etc/profile.d/deploy_server.sh  | awk -F'=' '{print $2}' | xargs)
  export PATH=$path
  fi

  # Define an array of helper scripts
  helper_scripts=(
      "${script_directory}/helpers/script_helpers.sh"
      "${script_directory}/helpers/common_utils.sh"
      "${script_directory}/deploy_utils.sh"
  )

  # Call the function with the array
  source_helper_scripts "${helper_scripts[@]}"

  # Parse command line arguments
  parse_arguments "$@"

  echo "ADO flag:                            ${ado_flag}"
  echo "Deploy using MSI only:               ${deploy_using_msi_only}"
  echo "Recover:                             ${recover}"
  echo "Auto-approve:                        ${approve}"
  echo "Force:                               ${force}"

  # Set the current directory as root directory for calculating relative paths
  root_dirname=$(pwd)

  # Get the ip address of the current machine
  this_ip=$(curl -s ipinfo.io/ip) >/dev/null 2>&1
  echo "Agent IP address:                    ${this_ip}"
  if [ ! -f /etc/profile.d/deploy_server.sh ] ; then
      export TF_VAR_Agent_IP=$this_ip
  fi

  if [ -n "$approve" ]; then
      approveparam=" --auto-approve"
  fi

  # check if the deployer parameter file exists
  if [ ! -f "$deployer_parameter_file" ]; then
      export missing_value='deployer parameter file'
      control_plane_missing
      exit 2 #No such file or directory
  fi

  # check if the library parameter file exists
  if [ ! -f "$library_parameter_file" ]; then
      export missing_value='library parameter file'
      control_plane_missing
      exit 2 #No such file or directory
  fi

  # Example usage of check_command_installed function to check for 'az' command
  # check_command_installed "az" "You can install Azure CLI by following the instructions at https://docs.microsoft.com/en-us/cli/azure/install-azure-cli"

  # Validate dependencies and exports
  validate_dependencies
  return_code=$?
  if [ 0 != $return_code ]; then
      echo "validate_dependencies returned $return_code"
      exit $return_code
  fi

  # Check that parameter files have environment and location defined
  validate_key_parameters "$deployer_parameter_file"
  if [ 0 != $return_code ]; then
      echo "Errors in parameter file" > "${deployer_config_information}".err
      exit $return_code
  fi

  # Convert the region to the correct code
  get_region_code "$region"

  echo "Region code:                         ${region_code}"

  validate_exports

  # Initialize configuration
  init_config

  # Execute deployment steps
  execute_deployment_steps

  print_banner "Success" "Bootstrapping the deployer completed successfully." "success"
  log "Bootstrapping the deployer completed successfully."
}

# Function to parse command line arguments
parse_arguments() {
  local input_opts
  input_opts=$(getopt -n deploy_controlplane -o d:l:s:c:p:t:a:k:ifohrvm --longoptions deployer_parameter_file:,library_parameter_file:,subscription:,spn_id:,spn_secret:,tenant_id:,storageaccountname:,vault:,auto-approve,force,only_deployer,help,recover,ado,msi -- "$@")
  is_input_opts_valid=$?

  if [[ "${is_input_opts_valid}" != "0" ]]; then
      control_plane_showhelp
      exit 1
  fi

  eval set -- "$input_opts"
  while true; do
    case "$1" in
      -d|--deployer_parameter_file) deployer_parameter_file="$2"; shift 2 ;;
      -l|--library_parameter_file) library_parameter_file="$2"; shift 2 ;;
      -s|--subscription) subscription="$2"; shift 2 ;;
      -c|--spn_id) client_id="$2"; shift 2 ;;
      -p|--spn_secret) spn_secret="$2"; shift 2 ;;
      -t|--tenant_id) tenant_id="$2"; shift 2 ;;
      -a|--storageaccountname) remote_state_sa="$2"; shift 2 ;;
      -k|--vault) keyvault="$2"; shift 2 ;;
      -f|--force) force=1; shift ;;
      -i|--auto-approve) approve="--auto-approve"; shift ;;
      -m|--msi) deploy_using_msi_only=1; shift ;;
      -r|--recover) recover=1; shift ;;
      -v|--ado) ado_flag="--ado"; shift ;;
      -h|--help) control_plane_showhelp; exit 0 ;;
      --) shift; break ;;
      *) echo "Invalid option: $1" >&2; control_plane_showhelp; exit 1 ;;
    esac
  done

  print_banner "Parsed Arguments" "deployer_parameter_file: $deployer_parameter_file,\n library_parameter_file: $library_parameter_file,\n subscription: $subscription,\n client_id: $client_id,\n tenant_id: $tenant_id,\n keyvault: $keyvault,\n force: $force,\n recover: $recover,\n ado_flag: $ado_flag,\n deploy_using_msi_only: $deploy_using_msi_only,\n approve: $approve\n" "info"

  # Validate required parameters
  [[ -z "$deployer_parameter_file" ]] && { print_banner "Deploy-Controlplane" "deployer_parameter_file is required" "error"; exit 1; }
  [[ -z "$library_parameter_file" ]] && { print_banner "Deploy-Controlplane" "library_parameter_file is required" "error"; exit 1; }

  echo "Deployer Parameter File:             ${deployer_parameter_file}"
  key=$(basename "${deployer_parameter_file}" | cut -d. -f1)
  deployer_tfstate_key="${key}.terraform.tfstate"
  echo "Deployer State File:                 ${deployer_tfstate_key}"
  echo "Deployer Subscription:               ${subscription}"

  echo "Library Parameter File:              ${library_parameter_file}"
  key=$(basename "${library_parameter_file}" | cut -d. -f1)
  library_tfstate_key="${key}.terraform.tfstate"
  echo "Library State File:                  ${library_tfstate_key}"

  #export the tfstatekey parameters
  export deployer_tfstate_key
  export library_tfstate_key
}

# Function to initialize configuration
init_config() {
  local generic_config_file="${CONFIG_DIR}/config"
  local deployer_config_file="${CONFIG_DIR}/${environment}${region_code}"

  [[ $force -eq 1 && -f "$deployer_config_file" ]] && rm "$deployer_config_file"

  init "$CONFIG_DIR" "$generic_config_file" "$deployer_config_file"
  save_config_var "deployer_tfstate_key" "$deployer_config_file"
}

# Function to execute deployment steps
execute_deployment_steps() {
  local step
  load_config_vars "${deployer_config_file}" "step"

  while [[ $step -le 4 ]]; do
    case $step in
      0) bootstrap_deployer ;;
      1) validate_keyvault_access ;;
      2) bootstrap_library ;;
      3) migrate_deployer_state ;;
      4) migrate_library_state ;;
    esac
    ((step++))
    save_config_var "step" "${deployer_config_file}"
  done
}

# Function to bootstrap the deployer
bootstrap_deployer() {
  if [ 0 == $step ]; then
    print_banner "Bootstrap-Deployer" "Bootstrapping the deployer..." "info"

    allParams=$(printf " --parameterfile %s %s" "${deployer_file_parametername}" "${approveparam}")

    echo "${allParams}"

    cd "${deployer_dirname}" || exit

    if [ $force == 1 ]; then
      rm -Rf .terraform terraform.tfstate*
    fi

    "${SAP_AUTOMATION_REPO_PATH}"/deploy/scripts/install_deployer.sh $allParams
    return_code=$?
    if [ 0 != $return_code ]; then
      print_banner "Bootstrap-Deployer" "Bootstrapping of the deployer failed" "error"
      echo "Bootstrapping of the deployer failed" > "${deployer_config_information}".err
      exit 10
    fi

    load_config_vars "${deployer_config_information}" "keyvault"
    echo "Key vault:             ${keyvault}"

    if [ -z "$keyvault" ]; then
      print_banner "Bootstrap-Deployer" "Key vault not found in the configuration" "error"
      echo "Bootstrapping of the deployer failed" > "${deployer_config_information}".err
      exit 10
    fi

    #Persist the parameters
    if [ -n "$subscription" ]; then
      save_config_var "subscription" "${deployer_config_information}"
      export STATE_SUBSCRIPTION=$subscription
      save_config_var "STATE_SUBSCRIPTION" "${deployer_config_information}"
    fi

    if [ -n "$client_id" ]; then
        save_config_var "client_id" "${deployer_config_information}"
    fi

    if [ -n "$tenant_id" ]; then
        save_config_var "tenant_id" "${deployer_config_information}"
    fi

    if [ -n "${FORCE_RESET}" ]; then
      step=3
      save_config_var "step" "${deployer_config_information}"
      exit 0
    else
      export step=1
    fi
    save_config_var "step" "${deployer_config_information}"

    cd "$root_dirname" || exit
  fi
}

# Function to validate keyvault access
validate_keyvault_access() {
  echo "Validating keyvault access..."
  # Add implementation here
}

# Function to bootstrap the library
bootstrap_library() {
  if [ 2 == $step ]; then
    print_banner "Bootstrap-Library" "Bootstrapping the library..." "info"

    relative_path="${library_dirname}"
    export TF_DATA_DIR="${relative_path}/.terraform"
    relative_path="${deployer_dirname}"

    cd "${library_dirname}" || exit

    if [ $force == 1 ]; then
      rm -Rf .terraform terraform.tfstate*
    fi

    allParams=$(printf " -p %s -d %s %s" "${library_file_parametername}" "${relative_path}" "${approveparam}")

    "${SAP_AUTOMATION_REPO_PATH}"/deploy/scripts/install_library.sh $allParams
    return_code=$?
    if [ 0 != $return_code ]; then
      print_banner "Bootstrap-Library" "Bootstrapping of the SAP Library failed" "error"
      echo "Bootstrapping of the SAP Library failed" > "${deployer_config_information}".err
      step=1
      save_config_var "step" "${deployer_config_information}"
      exit 20
    fi
    terraform_module_directory="${SAP_AUTOMATION_REPO_PATH}"/deploy/terraform/bootstrap/sap_library/
    REMOTE_STATE_RG=$(terraform -chdir="${terraform_module_directory}" output -no-color -raw sapbits_sa_resource_group_name  | tr -d \")
    REMOTE_STATE_SA=$(terraform -chdir="${terraform_module_directory}" output -no-color -raw remote_state_storage_account_name | tr -d \")
    STATE_SUBSCRIPTION=$(terraform -chdir="${terraform_module_directory}" output -no-color -raw created_resource_group_subscription_id  | tr -d \")

    if [ $ado_flag != "--ado" ] ; then
      az storage account network-rule add -g "${REMOTE_STATE_RG}" --account-name "${REMOTE_STATE_SA}" --ip-address ${this_ip} --output none
    fi

    TF_VAR_sa_connection_string=$(terraform -chdir="${terraform_module_directory}" output -no-color -raw sa_connection_string | tr -d \")
    export TF_VAR_sa_connection_string

    secretname=sa-connection-string
    deleted=$(az keyvault secret list-deleted --vault-name "${keyvault}" --query "[].{Name:name} | [? contains(Name,'${secretname}')] | [0]" | tr -d \")
    if [ "${deleted}" == "${secretname}"  ]; then
      # print_banner "Bootstrap-Library" "Recovering secret ${secretname} in keyvault ${keyvault}" "info"
      echo -e "\t $cyan Recovering secret ${secretname} in keyvault ${keyvault} $resetformatting \n"
      az keyvault secret recover --name "${secretname}" --vault-name "${keyvault}"
      sleep 10
    fi

    v=""
    secret=$(az keyvault secret list --vault-name "${keyvault}" --query "[].{Name:name} | [? contains(Name,'${secretname}')] | [0]" | tr -d \")
    if [ "${secret}" == "${secretname}"  ];
    then
      v=$(az keyvault secret show --name "${secretname}" --vault-name "${keyvault}" --query value | tr -d \")
      if [ "${v}" != "${TF_VAR_sa_connection_string}" ] ; then
        az keyvault secret set --name "${secretname}" --vault-name "${keyvault}" --value "${TF_VAR_sa_connection_string}" --expires "$(date -d '+1 year' -u +%Y-%m-%dT%H:%M:%SZ)" --only-show-errors --output none
      fi
    else
      az keyvault secret set --name "${secretname}" --vault-name "${keyvault}" --value "${TF_VAR_sa_connection_string}" --expires "$(date -d '+1 year' -u +%Y-%m-%dT%H:%M:%SZ)" --only-show-errors --output none
    fi

    cd "${curdir}" || exit
    export step=3
    save_config_var "step" "${deployer_config_information}"

    if [[ -n "${ADO_BUILD_ID:-}" ]]; then
      echo "##vso[task.setprogress value=60;]Progress Indicator"
    else
      echo 'Progress Indicator: 60\% done'
    fi

  else
    print_banner "Bootstrap-Library" "Library is bootstrapped" "success"

    if [[ -n "${ADO_BUILD_ID:-}" ]]; then
      echo "##vso[task.setprogress value=60;]Progress Indicator"
    else
      echo 'Progress Indicator: 60\% done'
    fi

  fi
}

# Function to migrate the deployer state
migrate_deployer_state() {
  if [ 3 == $step ]; then
    print_banner "Migrate-Deployer-State" "Migrating the deployer state..." "info"

    cd "${deployer_dirname}" || exit

    # Remove the script file
    if [ -f post_deployment.sh ]; then
      rm post_deployment.sh
    fi

    secretname=sa-connection-string
    deleted=$(az keyvault secret list-deleted --vault-name "${keyvault}" --query "[].{Name:name} | [? contains(Name,'${secretname}')] | [0]" | tr -d \")
    if [ "${deleted}" == "${secretname}"  ]; then
      echo -e "\t $cyan Recovering secret ${secretname} in keyvault ${keyvault} $resetformatting \n"
      az keyvault secret recover --name "${secretname}" --vault-name "${keyvault}"
      sleep 10
    fi

    v=""
    secret=$(az keyvault secret list --vault-name "${keyvault}" --query "[].{Name:name} | [? contains(Name,'${secretname}')] | [0]" | tr -d \")
    if [ "${secret}" == "${secretname}"  ]; then
      TF_VAR_sa_connection_string=$(az keyvault secret show --name "${secretname}" --vault-name "${keyvault}" --query value | tr -d \")
      export TF_VAR_sa_connection_string
    fi

    if [[ -z $REMOTE_STATE_SA ]];
    then
      echo -e "\t $cyan Loading the state file information $resetformatting \n"
      load_config_vars "${deployer_config_information}" "REMOTE_STATE_SA"
    fi

    allParams=$(printf " --parameterfile %s --storageaccountname %s --type sap_deployer %s %s " "${deployer_file_parametername}" "${REMOTE_STATE_SA}" "${approveparam}" "${ado_flag}" )

    echo -e "$cyan calling installer.sh with parameters: $allParams"

    "${SAP_AUTOMATION_REPO_PATH}"/deploy/scripts/installer.sh $allParams
    return_code=$?
    if [ 0 != $return_code ]; then
      print_banner "Migrate-Deployer-State" "Migrating the deployer state failed" "error"
      echo "Migrating the deployer state failed" > "${deployer_config_information}".err
      exit 11
    fi

    cd "${curdir}" || exit
    export step=4
    save_config_var "step" "${deployer_config_information}"

  fi

  unset TF_DATA_DIR
  cd "$root_dirname" || exit

  load_config_vars "${deployer_config_information}" "keyvault"
  load_config_vars "${deployer_config_information}" "deployer_public_ip_address"
  load_config_vars "${deployer_config_information}" "REMOTE_STATE_SA"

}

# Function to migrate the library state
migrate_library_state() {
  if [ 4 == $step ]; then
    print_banner "Migrate-Library-State" "Migrating the library state..." "info"

    cd "${library_dirname}" || exit
    allParams=$(printf " --parameterfile %s --storageaccountname %s --type sap_library %s %s" "${library_file_parametername}" "${REMOTE_STATE_SA}" "${approveparam}"  "${ado_flag}")

    echo -e "$cyan calling installer.sh with parameters: $allParams"

    "${SAP_AUTOMATION_REPO_PATH}"/deploy/scripts/installer.sh "${allParams[@]}"
    return_code=$?
    if [ 0 != $return_code ]; then
      print_banner "Migrate-Library-State" "Migrating the SAP Library state failed" "error"
      echo "Migrating the SAP Library state failed" > "${deployer_config_information}".err
      exit 21
    fi

    cd "$root_dirname" || exit

    step=5
    save_config_var "step" "${deployer_config_information}"
  fi
}

# Run the main function if the script is not being sourced
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && main "$@"

