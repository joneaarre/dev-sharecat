#!/bin/bash
# uncomment to debug the script
#set -x
# copy the script below into your app code repo (e.g. ./scripts/build_image.sh) and 'source' it from your pipeline job
#    source ./scripts/build_image.sh
# alternatively, you can source it from online script:
#    source <(curl -sSL "https://raw.githubusercontent.com/open-toolchain/commons/master/scripts/build_image.sh")
# ------------------
# source: https://raw.githubusercontent.com/open-toolchain/commons/master/scripts/build_image.sh
echo "Build environment variables:"
echo "REGISTRY_URL=${REGISTRY_URL}"
echo "REGISTRY_NAMESPACE=${REGISTRY_NAMESPACE}"
echo "IMAGE_NAME=${IMAGE_NAME}"
echo "BUILD_NUMBER=${BUILD_NUMBER}"
echo "ARCHIVE_DIR=${ARCHIVE_DIR}"
echo "GIT_COMMIT=${GIT_COMMIT}"

echo -e "\\n=========================================================="
echo "CHECKING DOCKERFILE"
echo "Checking Dockerfile at the repository root"
if [ -f Dockerfile ]; then 
  echo "Dockerfile found"
else
    echo "Dockerfile not found"
    exit 1
fi

echo "Linting Dockerfile"
npm install -g dockerlint
dockerlint -f Dockerfile

# echo -e "Existing images in registry"
# ibmcloud cr images

TIMESTAMP=$( date -u "+%Y%m%d%H%M%SUTC")
IMAGE_TAG=${BUILD_NUMBER}-${TIMESTAMP}
if [ ! -z ${GIT_COMMIT} ]; then
  GIT_COMMIT_SHORT=$( echo ${GIT_COMMIT} | head -c 8 ) 
  IMAGE_TAG=${IMAGE_TAG}-${GIT_COMMIT_SHORT}; 
fi

echo -e "\\n=========================================================="
echo -e "BUILDING CONTAINER IMAGE: ${IMAGE_NAME}:${IMAGE_TAG}"
set -x
# Checking ig buildctl is installed
if which buildctl > /dev/null 2>&1; then
  buildctl --version
else 
  echo "Installing Buildkit builctl"
  curl -sL https://github.com/moby/buildkit/releases/download/v0.8.1/buildkit-v0.8.1.linux-amd64.tar.gz | tar -C /tmp -xz bin/buildctl && mv /tmp/bin/buildctl /usr/bin/buildctl && rmdir --ignore-fail-on-non-empty /tmp/bin
  buildctl --version
fi

# Create the config.json file to make private container registry accessible
export DOCKER_CONFIG=$(mktemp -d -t cr-config-XXXXXXXXXX)
kubectl create secret --dry-run=true --output=json \
  docker-registry registry-dockerconfig-secret \
  --docker-server=${REGISTRY_URL} \
  --docker-password=${PIPELINE_BLUEMIX_API_KEY} \
  --docker-username=iamapikey --docker-email=a@b.com | \
jq -r '.data[".dockerconfigjson"]' | base64 -d > ${DOCKER_CONFIG}/config.json

echo "=========================================================="
echo -e "BUILDING CONTAINER IMAGE: ${IMAGE_NAME}:${IMAGE_TAG}"
if [ -z "${DOCKER_ROOT}" ]; then DOCKER_ROOT=. ; fi
if [ -z "${DOCKER_FILE}" ]; then DOCKER_FILE=Dockerfile ; fi
if [ -z "$EXTRA_BUILD_ARGS" ]; then
  echo -e ""
else
  for buildArg in $EXTRA_BUILD_ARGS; do
    if [ "$buildArg" == "--build-arg" ]; then
      echo -e ""
    else      
      BUILD_ARGS="${BUILD_ARGS} --opt build-arg:$buildArg"
    fi
  done
fi
set -x
buildctl build \
    --frontend dockerfile.v0 --opt filename=${DOCKER_FILE} --local dockerfile=${DOCKER_ROOT} \
    ${BUILD_ARGS} --local context=${DOCKER_ROOT} \
    --import-cache type=registry,ref=${REGISTRY_URL}/${REGISTRY_NAMESPACE}/${IMAGE_NAME} \
    --output type=image,name="${REGISTRY_URL}/${REGISTRY_NAMESPACE}/${IMAGE_NAME}:${IMAGE_TAG}",push=true
set +x
ibmcloud cr image-inspect ${REGISTRY_URL}/${REGISTRY_NAMESPACE}/${IMAGE_NAME}:${IMAGE_TAG}

# Set PIPELINE_IMAGE_URL for subsequent jobs in stage (e.g. Vulnerability Advisor)
export PIPELINE_IMAGE_URL="$REGISTRY_URL/$REGISTRY_NAMESPACE/$IMAGE_NAME:$BUILD_NUMBER"

ibmcloud cr images --restrict ${REGISTRY_NAMESPACE}/${IMAGE_NAME}

echo -e "\\n=========================================================="
echo "CHECKING HELM CHART"
CHART_ROOT="./cloud/chart"
if [ -d ${CHART_ROOT} ]; then
  CHART_NAME=$(find ${CHART_ROOT}/. -maxdepth 2 -type d -name '[^.]?*' -printf %f -quit)
  CHART_PATH=${CHART_ROOT}/${CHART_NAME}
fi
if [ -z "${CHART_PATH}" ]; then
    echo -e "No Helm chart found for Kubernetes deployment under ${CHART_ROOT}/<CHART_NAME>."
    exit 1
else
    echo -e "Helm chart found for Kubernetes deployment : ${CHART_PATH}"
fi
echo "Linting Helm Chart"
helm lint ${CHART_PATH}

echo "Copy Helm chart along with the build"
if [ ! -d $ARCHIVE_DIR/CHART_ROOT ]; then # no need to copy if working in ./ already
  cp -r $CHART_ROOT $ARCHIVE_DIR/
fi

echo -e "\\n=========================================================="
echo "COPYING ARTIFACTS needed for deployment and testing (in particular build.properties)"

echo "Checking archive dir presence"
mkdir -p $ARCHIVE_DIR

# Persist env variables into a properties file (build.properties) so that all pipeline stages consuming this
# build as input and configured with an environment properties file valued 'build.properties'
# will be able to reuse the env variables in their job shell scripts.

# CHART information from build.properties is used in Helm Chart deployment to set the release name
echo "CHART_NAME=${CHART_NAME}" >> $ARCHIVE_DIR/build.properties
echo "CHART_PATH=${CHART_PATH}" >> $ARCHIVE_DIR/build.properties
# IMAGE information from build.properties is used in Helm Chart deployment to set the release name
echo "IMAGE_NAME=${IMAGE_NAME}" >> $ARCHIVE_DIR/build.properties
echo "IMAGE_TAG=${IMAGE_TAG}" >> $ARCHIVE_DIR/build.properties
# REGISTRY information from build.properties is used in Helm Chart deployment to generate cluster secret
echo "REGISTRY_URL=${REGISTRY_URL}" >> $ARCHIVE_DIR/build.properties
echo "REGISTRY_NAMESPACE=${REGISTRY_NAMESPACE}" >> $ARCHIVE_DIR/build.properties
echo "File 'build.properties' created for passing env variables to subsequent pipeline jobs:"
cat $ARCHIVE_DIR/build.properties

echo "Copy pipeline scripts along with the build"
# Copy scripts (incl. deploy scripts)
if [ -d ./scripts/ ]; then
  if [ ! -d $ARCHIVE_DIR/scripts/ ]; then # no need to copy if working in ./ already
    cp -r ./scripts/ $ARCHIVE_DIR/
  fi
fi

echo "Copy Helm chart along with the build"
if [ ! -d $ARCHIVE_DIR/chart/ ]; then # no need to copy if working in ./ already
  cp -r ./chart/ $ARCHIVE_DIR/
fi
