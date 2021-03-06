#!/bin/bash

set +e

kubectl apply -f https://github.com/Faithlife/minikube-registry-proxy/raw/master/kube-registry-proxy.yml
curl -L https://github.com/Faithlife/minikube-registry-proxy/raw/master/docker-compose.yml | MINIKUBE_IP=$(minikube ip) docker-compose -p mkr -f - up -d

while [[ "$(curl -s -o /dev/null -w ''%{http_code}'' localhost:5000)" != 200 ]]; do
  curl -s -o /dev/null -w ''%{http_code}'' localhost:5000
  echo "waiting for registry to be ready"
  sleep 10;
done 

docker push localhost:5000/kong

helm init --wait
helm repo add incubator https://kubernetes-charts-incubator.storage.googleapis.com/
helm repo update
helm install --dep-up --name kong --set image.repository=localhost,image.tag=5000/kong stable/kong

while [[ "$(kubectl get deployment kong-kong | tail -n +2 | awk '{print $4}')" != 1 ]]; do
  echo "waiting for Kong to be ready"
  kubectl get deployment kong-kong
  kubectl get all
  sleep 10;
done

HOST="$(kubectl get nodes --namespace default -o jsonpath='{.items[0].status.addresses[0].address}')"
echo $HOST
ADMIN_PORT=$(kubectl get svc --namespace default kong-kong-admin -o jsonpath='{.spec.ports[0].nodePort}')
echo $ADMIN_PORT
PROXY_PORT=$(kubectl get svc --namespace default kong-kong-proxy -o jsonpath='{.spec.ports[0].nodePort}')
echo $PROXY_PORT
CURL_COMMAND="curl -s -o /tmp/out.txt -w %{http_code} "
echo $CURL_COMMAND

if ! [ `$CURL_COMMAND --insecure https://$HOST:$ADMIN_PORT` == "200" ]; then
  echo "Can't invoke admin API"
  cat /tmp/out.txt
  exit 1
else
  echo "Admin API passed"
fi

RANDOM_SERVICE_NAME="randomapiname"
RESPONSE=`$CURL_COMMAND --insecure -d "name=$RANDOM_SERVICE_NAME&url=http://mockbin.org" https://$HOST:$ADMIN_PORT/services`
if ! [ $RESPONSE == "201" ]; then
  echo "Can't create service"
  cat /tmp/out.txt
  exit 1
else
  echo "Created a service successfully"
fi

sleep 5

SERVICE_ID=$(cat /tmp/out.txt | sed 's,^.*"id":"\([^"]*\)".*$,\1,')
RESPONSE=`$CURL_COMMAND --insecure -d "hosts[]=$RANDOM_SERVICE_NAME.com&service.id=$SERVICE_ID" https://$HOST:$ADMIN_PORT/routes`
if ! [ $RESPONSE == "201" ]; then
  echo "Can't create route"
  cat /tmp/out.txt
  exit 1
else
  echo "Created a route successfully"
fi

sleep 5

# Proxy Tests
RESPONSE=`$CURL_COMMAND -H "Host: $RANDOM_SERVICE_NAME.com" http://$HOST:$PROXY_PORT/request`
if ! [ $RESPONSE == "200" ]; then
  echo "Can't invoke API on HTTP"
  cat /tmp/out.txt
  exit 1
fi

echo "Proxy and Admin smoke tests passed"
exit 0
