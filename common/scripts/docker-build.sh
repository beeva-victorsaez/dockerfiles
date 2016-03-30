#!/bin/bash
# ------------------------------------------------------------------------
#
# Copyright 2016 WSO2, Inc. (http://wso2.com)
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License

# ------------------------------------------------------------------------
set -e

SECONDS=0
self_path=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )
source "${self_path}/base.sh"

# Show usage and exit
function showUsageAndExit() {
    echoError "Insufficient or invalid options provided!"
    echoBold "Usage: ./build.sh -v [product-version]"
    echo

    # op_versions=$(listFiles "${PUPPET_HOME}/hieradata/dev/wso2/${product_name}/")
    # op_versions_str=$(echo $op_versions | tr ' ' ',')
    # op_versions_str="${op_versions_str//,/, }"
    #
    # op_profiles=$(listFiles "${PUPPET_HOME}/hieradata/dev/wso2/${product_name}/$(echo $op_versions | head -n1 | awk '{print $1}')/")
    # op_profiles_str=$(echo $op_profiles | tr ' ' ',')
    # op_profiles_str="${op_profiles_str//.yaml/}"
    # op_profiles_str="${op_profiles_str//,/, }"
    # echo "Available product versions: ${op_versions_str}"
    # echo "Available product profiles: ${op_profiles_str}"
    # echo

    echoBold "Options:"
    echo
    echo -en "  -v\t"
    echo "[REQUIRED] Product version of $(echo $product_name | awk '{print toupper($0)}')"
    echo -en "  -l\t"
    echo "[OPTIONAL] '|' separated $(echo $product_name | awk '{print toupper($0)}') profiles to build. 'default' is selected if no value is specified."
    echo -en "  -i\t"
    echo "[OPTIONAL] Docker image version."
    echo -en "  -o\t"
    echo "[OPTIONAL] Preferred organization name. If not specified, will be kept empty."
    echo -en "  -q\t"
    echo "[OPTIONAL] Quiet flag. If used, the docker build run output will be suppressed."
    echo -en "  -r\t"
    echo "[OPTIONAL] Provisioning method. If not specified this is defaulted to \"vanilla\"."
    echo

#    ex_version=$(echo ${op_versions_str} | head -n1 | awk '{print $1}')
#    ex_profile=$(echo ${op_profiles_str} | head -n1 | awk '{print $1}')
#    echoBold "Ex: ./build.sh -v ${ex_version//,/} -l '${ex_profile//,/}'"
#    echo
    exit 1
}

function cleanup() {
    echoBold "Cleaning..."
    rm -rf "$dockerfile_path/scripts"
    if [ ! -z $httpserver_pid ]; then
        kill -9 $httpserver_pid > /dev/null 2>&1
    fi
}

function validateDockerVersion(){
    IFS='.' read -r -a version_1 <<< "$1"
    IFS='.' read -r -a version_2 <<< "$2"
    for ((i=0; i<${#version_1[@]}; i++))
    do
        if (( "${version_1[i]}" < "${version_2[i]}" ))
            then
            echoError "Docker version should be equal to or greater than ${min_required_docker_version} to build WSO2 Docker images. Found ${docker_version}"
            exit 1
        fi
    done
}

function findHostIP() {
    local _ip _line
    while IFS=$': \t' read -a _line ;do
        [ -z "${_line%inet}" ] &&
           _ip=${_line[${#_line[1]}>4?1:2]} &&
           [ "${_ip#127.0.0.1}" ] && echo $_ip && return 0
    done< <(LANG=C /sbin/ifconfig)
}

verbose=true
provision_method="vanilla"

while getopts :r:n:v:d:l:i:o:q FLAG; do
    case $FLAG in
        r)
            provision_method=$OPTARG
            ;;
        q)
            verbose=false
            ;;
        n)
            product_name=$OPTARG
            ;;
        v)
            product_version=$OPTARG
            ;;
        d)
            dockerfile_path=$OPTARG
            ;;
        i)
            image_version=$OPTARG
            ;;
        l)
            product_profiles=$OPTARG
            ;;
        o)
            organization_name=$OPTARG
            ;;
        \?)
            showUsageAndExit
            ;;
    esac
done

if [[ -z ${product_version} ]] || [[ -z ${product_name} ]] || [[ -z ${dockerfile_path} ]]; then
   showUsageAndExit
fi

# org name adjustment
if [ ! -z "$organization_name" ]; then
    organization_name="${organization_name}/"
fi

# Default values for optional args
if [ -z "$product_profiles" ]
then
    product_profiles="default"
fi

echo "Provisioning Method: ${provision_method}"
image_config_file=${self_path}/provision/${provision_method}/image-config.sh
image_prep_file=${self_path}/provision/${provision_method}/image-prep.sh
if [[ ! -f  ${image_config_file} ]]; then
    echoError "Image config script ${image_config_file} does not exist"
    exit 1
fi

if [[ ! -f  ${image_prep_file} ]]; then
    echoError "Image preparation script ${image_prep_file} does not exist"
    exit 1
fi

pushd "${self_path}/provision/${provision_method}" > /dev/null 2>&1
source image-prep.sh $*
popd > /dev/null 2>&1

# validate docker version against minimum required docker version
# docker_version=$(docker version --format '{{.Server.Version}}')
docker_version=$(docker version | grep 'Version:' | awk '{print $2}')
min_required_docker_version=1.9.0
validateDockerVersion "${docker_version}" "${min_required_docker_version}"

# Copy common files to Dockerfile context
echoBold "Creating Dockerfile context..."
mkdir -p "${dockerfile_path}/scripts"
cp "${self_path}/entrypoint.sh" "${dockerfile_path}/scripts/init.sh"
cp "${self_path}/provision/${provision_method}/image-config.sh" "${dockerfile_path}/scripts/image-config.sh"

# starting http server
echoBold "Starting HTTP server in ${file_location}/..."

# check if port 8000 is already in use
port_uses=$(lsof -i:8000 | wc -l)
if [ $port_uses -gt 1 ]; then
   echoError "Port 8000 seems to be already in use. Exiting..."
   exit 1
fi

# start the server in background
pushd ${file_location} > /dev/null 2>&1
python -m SimpleHTTPServer 8000 & > /dev/null 2>&1
httpserver_pid=$!
sleep 5
popd > /dev/null 2>&1

# get host machine ip
host_ip=$(findHostIP)
if [ -z "$host_ip" ]; then
    echoError "Could not find host ip address. Exiting..."
    exit 1
fi

httpserver_address="http://${host_ip}:8000"
echoBold "HTTP server started at ${httpserver_address}"

# Build image for each profile provided
IFS='|' read -r -a profiles_array <<< "${product_profiles}"
for profile in "${profiles_array[@]}"
do
    #add image version to tag if specified
    if [ -z "$image_version" ]; then
        image_version_section="${product_version}"
    else
        image_version_section="${product_version}-${image_version}"
    fi

    # set image name according to the profile list
    if [[ "${profile}" = "default" ]]; then
        image_name_section="${organization_name}${product_name}"
    else
        image_name_section="${organization_name}${product_name}-${profile}"
    fi

    image_id="${image_name_section}:${image_version_section}"

    image_exists=$(docker images $image_id | wc -l)
    if [ ${image_exists} == "2" ]; then
        askBold "Docker image \"${image_id}\" already exists? Overwrite? (y/n): "
        read -r overwrite_v
    fi

    if [ ${image_exists} == "1" ] || [ $overwrite_v == "y" ]; then

        # if there is a custom init.sh script supplied specific for the profile of this product, pack
        # it to ${dockerfile_path}/scripts/
        product_init_script_name="${product_name}-${profile}-init.sh"
        if [[ -f "${dockerfile_path}/${product_init_script_name}" ]]; then
            pushd "${dockerfile_path}" > /dev/null
            cp "${product_init_script_name}" scripts/
            popd > /dev/null
        fi

        echoBold "Building docker image ${image_id}..."

        build_cmd="docker build --no-cache=true \
        --build-arg WSO2_SERVER=\"${product_name}\" \
        --build-arg WSO2_SERVER_VERSION=\"${product_version}\" \
        --build-arg WSO2_SERVER_PROFILE=\"${profile}\" \
        --build-arg WSO2_ENVIRONMENT=\"${product_env}\" \
        --build-arg HTTP_PACK_SERVER=\"${httpserver_address}\" \
        -t \"${image_id}\" \"${dockerfile_path}\""

        {
            if [ $verbose == true ]; then
                ! eval $build_cmd | tee /dev/tty | grep -iq error && echo "Docker image ${image_id} created."
            else
                ! eval $build_cmd | grep -i error && echo "Docker image ${image_id} created."
            fi

        } || {
            echo
            echoError "ERROR: Docker image ${image_id} creation failed"
            cleanup
            exit 1
        }
    else
        echoBold "Not overwriting \"${image_id}\"..."
    fi
done

cleanup
duration=$SECONDS
echoSuccess "Build process completed in $(($duration / 60)) minutes and $(($duration % 60)) seconds"
