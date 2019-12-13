#!/usr/bin/env bash

#
# Prerequisite : install tool jq
# This script assumes that KubeDB & Component operators are installed
#
# End to end scenario to be executed on minikube, minishift or k8s cluster
# Example: ./scripts/end-to-end.sh <CLUSTER_IP> <NAMESPACE> <DEPLOYMENT_MODE> <DELETE_RESOURCES>
# where CLUSTER_IP represents the external IP address exposed top of the VM
#
# Updated : Aug 26
# Added:
# - Function to delete all the resources managed by the API within the namespace of the test
# - Add DIR var.
# - Use files generated by dekorate for the demo project
# - Add parameter to support to delete or not the resources
# - Replace the deploymentMode according to the parameter: $MODE

#
DIR=$(dirname "$0")
CLUSTER_IP=${1:-192.168.99.50}
NS=${2:-test}
MODE=${3:-dev}
DELETE_RESOURCES=${4:-false}

SLEEP_TIME=30s
TIME=$(date +"%Y-%m-%d_%H-%M")
REPORT_FILE="result_${TIME}.txt"
EXPECTED_RESPONSE='{"status":"UP"}'
EXPECTED_FRUITS='[{"id":1,"name":"Cherry"},{"id":2,"name":"Apple"},{"id":3,"name":"Banana"}]'

# Test if we run on plain k8s or openshift
res=$(kubectl api-versions | grep user.openshift.io/v1)
if [ "$res" == "" ]; then
  isOpenShift="false"
else
  isOpenShift="true"
fi

if [ "$MODE" == "build" ]; then
    COMPONENT_FRUIT_BACKEND_NAME="fruit-backend-sb-build"
    COMPONENT_FRUIT_CLIENT_NAME="fruit-client-sb-build"
else
    COMPONENT_FRUIT_BACKEND_NAME="fruit-backend-sb"
    COMPONENT_FRUIT_CLIENT_NAME="fruit-client-sb"
fi

function deleteResources() {
  result=$(kubectl api-resources --verbs=list --namespaced -o name | sort)
  for i in $result[@]
  do
    echo "==== Deleting: $i"
    kubectl delete $i --ignore-not-found=true --now=true --wait=false --all -n $NS
  done
}

function listAllK8sResources() {
  result=$(kubectl api-resources --verbs=list --namespaced -o name)
  for i in $result[@]
  do
    kubectl get $i --ignore-not-found=true -n $1
  done
}

function printTitle {
  r=$(typeset i=${#1} c="=" s="" ; while ((i)) ; do ((i=i-1)) ; s="$s$c" ; done ; echo  "$s" ;)
  printf "$r\n$1\n$r\n"
}

function waitForAndGetPodName() {
  local -r counterMax=24
  local -r sleepTime=5
  local counter=0
  local pod=""
  pod="$(kubectl get pods -n ${NS} -l app=${1} 2>/dev/null | grep 'Running')"
  local status=$?
  until [ "$counter" -gt "${counterMax}" ] || [ "$status" == 0 ]; do
    sleep "${sleepTime}"
    counter=$((counter + 1))
    pod="$(kubectl get pods -n ${NS} -l app=${1} 2>/dev/null | grep 'Running')"
    status=$?
  done

  if [ "$counter" -gt "${counterMax}" ]; then
    printf >&2 "Timed out waiting %d seconds for pod labeled app=%s to become Running" $((sleepTime * counterMax)) "${1}"
    exit 1
  fi

  pod=$(echo "${pod}" | cut -d' ' -f1)
  echo "${pod}"
}

if [ "$SKIP_DELETE_RESOURCES" == "true" ]; then
  printTitle "Clean all the resources created previously within the namespace: $NS"
  deleteResources
fi

printTitle "Creating the namespace"
kubectl create ns ${NS}

printTitle "Compile End to End Demo project"
sed -i '' "s/\(deploymentMode:\).*/\1 $MODE/g" "${DIR}"/../demo/fruit-backend-sb/src/main/resources/application.yml
cd "${DIR}"/../demo
./mvnw clean package -f fruit-backend-sb
cd -
sed -i '' "s/\(deploymentMode:\).*/\1 $MODE/g" "${DIR}"/../demo/fruit-client-sb/src/main/resources/application.yml
cd "${DIR}"/../demo
./mvnw clean package -f fruit-client-sb
cd -

printTitle "Deploy the component for the fruit-backend, link and capability"
kubectl apply -n "${NS}" -f "${DIR}"/../demo/fruit-backend-sb/target/classes/META-INF/dekorate/halkyon.yml
echo "Sleep ${SLEEP_TIME}"
sleep ${SLEEP_TIME}

printTitle "Deploy the component for the fruit-client, link"
kubectl apply -n "${NS}" -f "${DIR}"/../demo/fruit-client-sb/target/classes/META-INF/dekorate/halkyon.yml
echo "Sleep ${SLEEP_TIME}"
sleep ${SLEEP_TIME}

printTitle "Report status : ${TIME}" > ${REPORT_FILE}
printTitle "Kubernetes cluster info" >> ${REPORT_FILE}
kubectl cluster-info >> ${REPORT_FILE}

printTitle "1. Status of the resources created using the CRDs : Component, Link or Capability" >> ${REPORT_FILE}
if [ "$isOpenShift" == "true" ]; then
  for i in components links capabilities pods deployments deploymentconfigs services routes pvc postgreses secret/postgres-db-config
  do
    printTitle "$(echo $i | tr a-z A-Z)" >> ${REPORT_FILE}
    kubectl get $i -n ${NS} >> ${REPORT_FILE}
    printf "\n" >> ${REPORT_FILE}
  done
else
  for i in components links capabilities pods deployments services ingresses pvc postgreses secret/postgres-db-config
  do
    printTitle "$(echo $i | tr a-z A-Z)" >> ${REPORT_FILE}
    kubectl get $i -n ${NS} >> ${REPORT_FILE}
    printf "\n" >> ${REPORT_FILE}
  done
fi

if [ "$MODE" == "build" ]; then
   printTitle "1. Log of the Tekton's task pod and containers executing the steps" >> ${REPORT_FILE}
   for i in fruit-backend-sb fruit-client-sb; do
     until kubectl get pods -n $NS -ltekton.dev/task=s2i-buildah-push,build=$i | grep "Running"; do sleep 5; done
     printTitle "1.1. Step generate Dockerfile for $i" >> ${REPORT_FILE}
     kubectl logs -f -n ${NS} $(kubectl get pods -n $NS -ltekton.dev/task=s2i-buildah-push,build=$i -o name) -c step-generate >> ${REPORT_FILE}
     printf "\n" >> ${REPORT_FILE}
     printTitle "1.2. Step s2i maven build for $i" >> ${REPORT_FILE}
     kubectl logs -f -n ${NS} $(kubectl get pods -n $NS -ltekton.dev/task=s2i-buildah-push,build=$i -o name) -c step-build >> ${REPORT_FILE}
     printf "\n" >> ${REPORT_FILE}
     printTitle "1.3. Step docker push for $i" >> ${REPORT_FILE}
     kubectl logs -f -n ${NS} $(kubectl get pods -n $NS -ltekton.dev/task=s2i-buildah-push,build=$i -o name) -c step-push >> ${REPORT_FILE}
     printf "\n" >> ${REPORT_FILE}
   done
fi

printTitle "2. ENV injected to the fruit backend component"
printTitle "2. ENV injected to the fruit backend component" >> ${REPORT_FILE}
until kubectl get pods -n $NS -l app=$COMPONENT_FRUIT_BACKEND_NAME | grep "Running"; do sleep 5; done
kubectl exec -n ${NS} $(kubectl get pod -n ${NS} -lapp=$COMPONENT_FRUIT_BACKEND_NAME | grep "Running" | awk '{print $1}') env | grep DB >> ${REPORT_FILE}
printf "\n" >> ${REPORT_FILE}

printTitle "3. ENV var defined for the fruit client component"
printTitle "3. ENV var defined for the fruit client component" >> ${REPORT_FILE}
until kubectl get pods -n $NS -l app=$COMPONENT_FRUIT_CLIENT_NAME | grep "Running"; do sleep 5; done
for item in $(kubectl get pod -n ${NS} -lapp=$COMPONENT_FRUIT_CLIENT_NAME --output=name); do printf "Envs for %s\n" "$item" | grep --color -E '[^/]+$' && kubectl get "$item" -n ${NS} --output=json | jq -r -S '.spec.containers[0].env[] | " \(.name)=\(.value)"' 2>/dev/null; printf "\n"; done >> ${REPORT_FILE}
printf "\n" >> ${REPORT_FILE}

if [ "$MODE" == "dev" ]; then
  printTitle "Push fruit client and backend"
  ./demo/scripts/k8s_push_start.sh fruit-backend sb ${NS}
  ./demo/scripts/k8s_push_start.sh fruit-client sb ${NS}
fi

printTitle "Wait until Spring Boot actuator health replies UP for both microservices"
maxRetries=12
httpSleepTime=10
for i in $COMPONENT_FRUIT_BACKEND_NAME $COMPONENT_FRUIT_CLIENT_NAME; do
  HTTP_BODY=""
  counter=0
  podName="$(waitForAndGetPodName ${i})"
  if [ $? != 0 ]; then
    exit 1
  fi
  until [ "$counter" -gt "${maxRetries}" ] || [ "$HTTP_BODY" == "$EXPECTED_RESPONSE" ]; do
    HTTP_RESPONSE=$(kubectl exec -n "${NS}" "${podName}" -- curl -L -w "HTTPSTATUS:%{http_code}" -s localhost:8080/actuator/health 2>&1)
    HTTP_BODY=$(echo $HTTP_RESPONSE | sed -e 's/HTTPSTATUS\:.*//g')
    echo "$i: Response is : $HTTP_BODY, expected is : $EXPECTED_RESPONSE"
    sleep "${httpSleepTime}"
    counter=$((counter + 1))
  done
  if [ "$counter" -gt "${maxRetries}" ]; then
    printf "Timed out waiting %d seconds for %s microservice to become UP" $((httpSleepTime * maxRetries)) "${i}"
    exit 1
  fi
done

printTitle "Curl Fruit service"
printTitle "4. Curl Fruit Endpoint service" >>${REPORT_FILE}

if [ "$isOpenShift" == "true" ]; then
  echo "No ingress resources found. We run on OpenShift" >>${REPORT_FILE}
  FRONTEND_ROUTE_URL=$(kubectl get route/fruit-client-sb -o jsonpath='{.spec.host}' -n ${NS})
  CURL_RESPONSE=$(curl http://$FRONTEND_ROUTE_URL/api/client)
  echo $CURL_RESPONSE >>${REPORT_FILE}
else
  CURL_RESPONSE=$(curl -H "Host: fruit-client-sb" http://${CLUSTER_IP}/api/client)
  echo $CURL_RESPONSE >>${REPORT_FILE}
fi

if [ "$CURL_RESPONSE" == "$EXPECTED_FRUITS" ]; then
  printTitle "CALLING FRUIT ENDPOINT SUCCEEDED USING MODE : $MODE :-)"
else
  printTitle "FAILED TO CALL FRUIT ENDPOINT USING MODE : $MODE :-("
  exit 1
fi

if [ "$DELETE_RESOURCES" == "true" ]; then
  printTitle "Delete the resources components, links and capabilities"
  if [ "$isOpenShift" == "true" ]; then
    kubectl delete components,links,capabilities,imagestreams --all -n ${NS}
  else
    kubectl delete components,links,capabilities --all -n ${NS}
  fi
fi

git checkout -- demo/fruit-backend-sb/src/main/resources/application.yml
git checkout -- demo/fruit-client-sb/src/main/resources/application.yml