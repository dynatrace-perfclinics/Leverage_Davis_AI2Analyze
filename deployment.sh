#!/usr/bin/env bash

################################################################################
### Script deploying the Observ-K8s environment
### Parameters:
### dttoken : Dynatrace Data ingest Api token ( Required)
### paastoken : Dynatrace Paas Api token  ( Required)
### dturl: Dynatrace url including https ( Required)
### oteldemo_version: Otel-demo version ( not manadatory , default value: v1.0.0
################################################################################


### Pre-flight checks for dependencies
if ! command -v jq >/dev/null 2>&1; then
    echo "Please install jq before continuing"
    exit 1
fi

if ! command -v git >/dev/null 2>&1; then
    echo "Please install git before continuing"
    exit 1
fi


if ! command -v helm >/dev/null 2>&1; then
    echo "Please install helm before continuing"
    exit 1
fi

if ! command -v kubectl >/dev/null 2>&1; then
    echo "Please install kubectl before continuing"
    exit 1
fi

while [ $# -gt 0 ]; do
  case "$1" in
  --dttoken)
    DTTOKEN="$2"
    ;;
  --dturl)
    DTURL="$2"
    ;;
  --paastoken)
    DTPAASTOKEN="$2"
    ;;
  --clustername)
    CLUSTERNAME="$2"
    ;;
  --oteldemo_version)
    VERSION="$2"
    ;;
  *)
    echo "Warning: skipping unsupported option: $1"
    shift
    ;;
  esac
done

if [ -z "$CLUSTERNAME" ]; then
  echo "Error: clustername not set!"
  exit 1
fi

if [ -z "$VERSION" ]; then
  VERSION=v1.0.0
  echo "Deploying the Otel demo version $VERSION"
fi

if [ -z "$DTURL" ]; then
  echo "Error: environment-url not set!"
  exit 1
fi

if [ -z "$DTTOKEN" ]; then
  echo "Error: api-token not set!"
  exit 1
fi

if [ -z "$DTPAASTOKEN" ]; then
  echo "Error: paas-token not set!"
  exit 1
fi



###### Deploy Nginx
echo "start depploying Nginx"
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update
helm upgrade --install ingress-nginx ingress-nginx \
  --repo https://kubernetes.github.io/ingress-nginx \
  --namespace ingress-nginx --create-namespace

### get the ip adress of ingress ####
IP=""
while [ -z $IP ]; do
  echo "Waiting for external IP"
  IP=$(kubectl get svc ingress-nginx-controller -n ingress-nginx -ojson | jq -j '.status.loadBalancer.ingress[].ip')
  [ -z "$IP" ] && sleep 10
done
echo 'Found external IP: '$IP

### Update the ip of the ip adress for the ingres
#TODO to update this part to use the dns entry /ELB/ALB
sed -i "s,IP_TO_REPLACE,$IP," kubernetes-manifests/K8sdemo.yaml
sed -i "s,IP_TO_REPLACE,$IP," kubernetes-manifests/K8sdemo_reducecost.yaml
sed -i "s,IP_TO_REPLACE,$IP," kubernetes-manifests/K8sdemo_reducefailure.yaml
sed -i "s,IP_TO_REPLACE,$IP," grafana/ingress.yaml

### Replace cluster name
sed -i "s,CLUSTER_NAME_TO_REPLACE,$CLUSTERNAME," dynatrace/dynakube.yaml
sed -i "s,CLUSTER_NAME_TO_REPLACE,$CLUSTERNAME," kubernetes-manifests/openTelemetry-sidecar.yaml


#### Deploy the cert-manager
echo "Deploying Cert Manager ( for OpenTelemetry Operator)"
kubectl apply -f https://github.com/jetstack/cert-manager/releases/download/v1.6.1/cert-manager.yaml
# Wait for pod webhook started
kubectl wait pod -l app.kubernetes.io/component=webhook -n cert-manager --for=condition=Ready --timeout=2m

# Deploy the opentelemetry operator
echo "Deploying the OpenTelemetry Operator"
kubectl apply -f https://github.com/open-telemetry/opentelemetry-operator/releases/latest/download/opentelemetry-operator.yaml


#Deploy Prometheus Operator
echo "start depploying Prometheus"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
helm install prometheus prometheus-community/kube-prometheus-stack --set grafana.sidecar.dashboards.enabled=true --set sidecar.datasources.enabled=true --set sidecar.datasources.label=grafana_datasource --set sidecar.datasources.labelValue="1" --set sidecar.dashboards.enabled=true
##wait that the prometheus pod is started
kubectl wait pod --namespace default -l "release=prometheus" --for=condition=Ready --timeout=2m
PROMETHEUS_SERVER=$(kubectl get svc -l app=kube-prometheus-stack-prometheus -o jsonpath="{.items[0].metadata.name}")
echo "Prometheus service name is $PROMETHEUS_SERVER"
GRAFANA_SERVICE=$(kubectl get svc -l app.kubernetes.io/name=grafana -o jsonpath="{.items[0].metadata.name}")
echo "Grafana service name is  $GRAFANA_SERVICE"
ALERT_MANAGER_SVC=$(kubectl get svc -l app=kube-prometheus-stack-alertmanager -o jsonpath="{.items[0].metadata.name}")
echo "Alertmanager service name is  $ALERT_MANAGER_SVC"


#Deploy DT Operator
#### Create the k8s secret for our tokenks
kubectl create namespace dynatrace
kubectl -n dynatrace create secret generic dynakube --from-literal="apiToken=$DTPAASTOKEN" --from-literal="dataIngestToken=$DTTOKEN"
#### Deploy deploy the Dynatrace operator
kubectl apply -f https://github.com/Dynatrace/dynatrace-operator/releases/latest/download/kubernetes.yaml
kubectl apply -f https://github.com/Dynatrace/dynatrace-operator/releases/latest/download/kubernetes-csi.yaml
sed -i "s,TENANTURL_TOREPLACE,$DTURL," dynatrace/dynakube.yaml
kubectl apply -f dynatrace/dynakube.yaml

#Deploy the OpenTelemetry Collector
echo "Deploying Otel Collector"
CLUSTERID=$(kubectl get namespace kube-system -o jsonpath='{.metadata.uid}')
sed -i "s,CLUSTER_ID_TOREPLACE,$CLUSTERID," kubernetes-manifests/openTelemetry-sidecar.yaml
sed -i "s,DT_URL_TO_REPLACE,$DTURL," kubernetes-manifests/openTelemetry-manifest.yaml
sed -i "s,DT_TOKEN_TO_REPLACE,$DTTOKEN," kubernetes-manifests/openTelemetry-manifest.yaml
kubectl apply -f kubernetes-manifests/rbac.yaml
kubectl apply -f kubernetes-manifests/openTelemetry-manifest.yaml


#Deploy demo Application
echo "Deploying otel-demo"
sed -i "s,VERSION_TO_REPLACE,$VERSION," kubernetes-manifests/K8sdemo.yaml
sed -i "s,VERSION_TO_REPLACE,$VERSION," kubernetes-manifests/K8sdemo_reducecost.yaml
sed -i "s,VERSION_TO_REPLACE,$VERSION," kubernetes-manifests/K8sdemo_reducefailure.yaml
kubectl create ns otel-demo
kubectl annotate ns otel-demo chaos-mesh.org/inject=enabled
kubectl apply -f kubernetes-manifests/openTelemetry-sidecar.yaml -n  otel-demo
kubectl apply -f kubernetes-manifests/K8sdemo.yaml -n  otel-demo

echo "Deploying Kubecost"
# Deploy Kubecost
kubectl create namespace kubecost
helm repo add kubecost https://kubecost.github.io/cost-analyzer/
helm install kubecost kubecost/cost-analyzer --namespace kubecost --set kubecostToken="aGVucmlrLnJleGVkQGR5bmF0cmFjZS5jb20=xm343yadf98" --set prometheus.kube-state-metrics.disabled=true --set prometheus.nodeExporter.enabled=false --set ingress.enabled=true --set ingress.hosts[0]="kubecost.$IP.nip.io" --set global.grafana.enabled=false --set global.grafana.fqdn="http://$GRAFANA_SERVICE.default.svc" --set prometheusRule.enabled=true --set global.prometheus.fqdn="http://$PROMETHEUS_SERVER.default.svc:9090" --set global.prometheus.enabled=false --set serviceMonitor.enabled=true
kubectl apply -f kubecost/PrometheusRule.yaml
kubectl create secret generic addtional-scrape-configs --from-file=kubecost/additionnalscrapeconfig.yaml

# Echo environ*
echo "========================================================"
echo "Environment fully deployed "
echo "Grafana url : http://grafana.$IP.nip.io"
echo "Grafana User: $USER_GRAFANA"
echo "Grafana Password: $PASSWORD_GRAFANA"
echo "-----------------------------------------"
echo "url of the demo: "
echo "Otel demo url: http://demo.$IP.nip.io"
echo "Locust: http://locust.$IP.nip.io"
echo "FeatureFlag : http://featureflag.$IP.nip.io"
echo "------------------------------------------"
echo "KubeCost url: http://kubecost.$IP.nip.io"
echo "========================================================"
