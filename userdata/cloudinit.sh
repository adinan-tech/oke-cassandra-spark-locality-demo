#!/bin/bash
set -o pipefail
LOG_FILE="/var/log/oke-automation.log"

log() {
  echo "$(date) [CLOUDINIT]: $*" | tee -a "${LOG_FILE}"
}

log "Starting cloudinit setup"

# Get region and cluster ID
region=$(curl -s -H "Authorization: Bearer Oracle" http://169.254.169.254/opc/v2/instance/regionInfo/regionIdentifier)
oke_cluster_id=$(curl -s -H "Authorization: Bearer Oracle" http://169.254.169.254/opc/v1/instance/metadata/oke_cluster_id)

# Add Kubernetes repo
cat <<EOF | sudo tee /etc/yum.repos.d/kubernetes.repo
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/v1.29/rpm/
enabled=1
gpgcheck=0
repo_gpgcheck=0
gpgkey=https://pkgs.k8s.io/core:/stable:/v1.29/rpm/repodata/repomd.xml.key
EOF

# Install kubectl and git
yum install -y kubectl git >> "$LOG_FILE" 2>&1

# Install Helm
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash >> "$LOG_FILE" 2>&1

# Install Python 3.9 and OCI CLI in venv (no cryptography warnings)
dnf module enable python39 -y >> "$LOG_FILE" 2>&1
dnf install -y python39 python39-devel gcc redhat-rpm-config libffi-devel openssl-devel >> "$LOG_FILE" 2>&1

# Create virtual environment and install oci-cli cleanly
/usr/bin/python3.9 -m venv /home/opc/oci39env
source /home/opc/oci39env/bin/activate
/home/opc/oci39env/bin/pip install --upgrade pip >> "$LOG_FILE" 2>&1
/home/opc/oci39env/bin/pip install oci-cli >> "$LOG_FILE" 2>&1

# Symlink oci for global use
ln -sf /home/opc/oci39env/bin/oci /usr/local/bin/oci
chmod +x /usr/local/bin/oci

# Set instance principal for authentication
export OCI_CLI_AUTH=instance_principal


# Enable OCI + kubectl for opc and root
for user in root opc; do
  user_home=$(eval echo "~$user")
  echo 'export PATH=$PATH:/usr/local/bin' >> "$user_home/.bashrc"
  echo 'export OCI_CLI_AUTH=instance_principal' >> "$user_home/.bashrc"
  echo 'source <(kubectl completion bash)' >> "$user_home/.bashrc"
  echo "alias k='kubectl'" >> "$user_home/.bashrc"
done

# Fix ownership for opc files
chown opc:opc /home/opc/.bashrc /home/opc/.bash_profile 2>/dev/null || true


# Set up kubeconfig
mkdir -p /root/.kube /home/opc/.kube

log "Fetching kubeconfig..."
for i in {1..10}; do
  oci ce cluster create-kubeconfig \
    --cluster-id "${oke_cluster_id}" \
    --file /root/.kube/config \
    --region "${region}" \
    --token-version 2.0.0 && break
  sleep 10
done

if [ ! -f /root/.kube/config ]; then
  log "Failed to fetch kubeconfig"
  exit 1
fi

cp /root/.kube/config /home/opc/.kube/config
chown -R opc:opc /home/opc/.kube

log "Versions:"
oci --version >> "$LOG_FILE"
kubectl version --client --output=yaml >> "$LOG_FILE"
helm version --template "{{.Version}}" >> "$LOG_FILE"

log "Sleeping 10 minutes before continuing..."
# Wait 10 minutes to give OKE nodes time to register
sleep 600

log "Make sure opc has access to kubeconfig"
mkdir -p /home/opc/.kube
cp /root/.kube/config /home/opc/.kube/config
chown opc:opc /home/opc/.kube/config
chmod 600 /home/opc/.kube/config

log "Set KUBECONFIG for interactive sessions"
echo 'export KUBECONFIG=$HOME/.kube/config' >> /home/opc/.bashrc

export KUBECONFIG=/root/.kube/config
kubectl get nodes >> "$LOG_FILE" 2>&1


log "Waiting for at least 2 nodes to be Ready before labeling..."
ATTEMPTS=0
MAX_ATTEMPTS=40
while true; do
  READY_COUNT=$(kubectl get nodes 2>/dev/null | grep -c ' Ready')
  if [ "$READY_COUNT" -ge 2 ]; then
    log "Found $READY_COUNT Ready nodes, continuing with labeling..."
    break
  fi
  if [ "$ATTEMPTS" -ge "$MAX_ATTEMPTS" ]; then
    log "Timeout waiting for nodes to be Ready"
    break
  fi
  sleep 15
  ((ATTEMPTS++))
done


log "Label first 2 nodes with data-locality and spark-locality, using zone-based roles"
echo "Labeling the first two nodes..."
NODES=$(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | head -n 2)
i=0
for NODE in $NODES; do
  if [ $i -eq 0 ]; then
    ZONE_LABEL="zone-a"
  else
    ZONE_LABEL="zone-b"
  fi
  echo "Labeling node $NODE with zone $ZONE_LABEL..."
  kubectl label node "$NODE" spark-locality=true data-locality=enabled node-role=$ZONE_LABEL --overwrite
  ((i++))
done

# Install cert-manager using Helm
log "Installing cert-manager..."

export KUBECONFIG=/root/.kube/config

/usr/local/bin/helm repo add jetstack https://charts.jetstack.io >> "$LOG_FILE" 2>&1
/usr/local/bin/helm repo update >> "$LOG_FILE" 2>&1

/usr/local/bin/helm install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --set installCRDs=true >> "$LOG_FILE" 2>&1

log "Wait for cert-manager pods to start running"

ATTEMPTS=0
MAX_ATTEMPTS=30
echo "Waiting for cert-manager pods..." >> "$LOG_FILE"
until kubectl get pods -n cert-manager 2>/dev/null | grep -q 'Running'; do
  if [ "$ATTEMPTS" -ge "$MAX_ATTEMPTS" ]; then
    echo "Timeout waiting for cert-manager pods to be Running" >> "$LOG_FILE"
    break
  fi
  sleep 10
  ((ATTEMPTS++))
done

kubectl get pods -n cert-manager >> "$LOG_FILE" 2>&1

log "Installing K8ssandra Operator v1.7.1..."

/usr/local/bin/helm repo add k8ssandra https://helm.k8ssandra.io/stable >> "$LOG_FILE" 2>&1
/usr/local/bin/helm repo update >> "$LOG_FILE" 2>&1

/usr/local/bin/helm install k8ssandra-operator k8ssandra/k8ssandra-operator \
  --namespace k8ssandra-operator \
  --create-namespace \
  --version 1.7.1 \
  --set installCRDs=true >> "$LOG_FILE" 2>&1

log "Waiting for K8ssandra Operator pods to be Running..."

ATTEMPTS=0
MAX_ATTEMPTS=30
while true; do
  READY_PODS=$(kubectl get pods -n k8ssandra-operator --no-headers 2>/dev/null | grep -c 'Running')
  TOTAL_PODS=$(kubectl get pods -n k8ssandra-operator --no-headers 2>/dev/null | wc -l)
  if [ "$TOTAL_PODS" -gt 0 ] && [ "$READY_PODS" -eq "$TOTAL_PODS" ]; then
    break
  fi
  if [ "$ATTEMPTS" -ge "$MAX_ATTEMPTS" ]; then
    log "Timeout waiting for K8ssandra Operator pods"
    break
  fi
  sleep 10
  ((ATTEMPTS++))
done

kubectl get pods -n k8ssandra-operator >> "$LOG_FILE" 2>&1
kubectl get crd k8ssandraclusters.k8ssandra.io >> "$LOG_FILE" 2>&1
/usr/local/bin/helm list -n k8ssandra-operator >> "$LOG_FILE" 2>&1

log "Verifying K8ssandra CRD installation"
kubectl get crds | grep k8ssandra >> "$LOG_FILE" 2>&1

log "K8ssandra Operator: $READY_PODS/$TOTAL_PODS pods Running..."

log "Creating embedded K8ssandraCluster manifest..."

cat <<EOF | tee /root/k8ssandracluster.yaml >> "$LOG_FILE"
apiVersion: k8ssandra.io/v1alpha1
kind: K8ssandraCluster
metadata:
  name: my-k8ssandra-cluster
  namespace: k8ssandra-operator
spec:
  cassandra:
    serverVersion: "4.0.6"
    datacenters:
      - metadata:
          name: dc1
        size: 2
        racks:
          - name: default
            nodeAffinityLabels:
              spark-locality: "true"
        storageConfig:
          cassandraDataVolumeClaimSpec:
            accessModes: [ "ReadWriteOnce" ]
            resources:
              requests:
                storage: 10Gi
            storageClassName: oci
EOF

log "Applying K8ssandraCluster manifest..."
kubectl apply -f /root/k8ssandracluster.yaml -n k8ssandra-operator >> "$LOG_FILE" 2>&1

log "Waiting for Cassandra pods to start (up to 10 mins)..."
ATTEMPTS=0
MAX_ATTEMPTS=60
while true; do
  CASS_PODS=$(kubectl get pods -n k8ssandra-operator -l app.kubernetes.io/name=cassandra --no-headers 2>/dev/null | grep -c 'Running')
  TOTAL_PODS=$(kubectl get pods -n k8ssandra-operator -l app.kubernetes.io/name=cassandra --no-headers 2>/dev/null | wc -l)
  if [ "$TOTAL_PODS" -gt 0 ] && [ "$CASS_PODS" -eq "$TOTAL_PODS" ]; then
    break
  fi
  if [ "$ATTEMPTS" -ge "$MAX_ATTEMPTS" ]; then
    log "Timeout waiting for Cassandra pods"
    break
  fi
  sleep 10
  ((ATTEMPTS++))
done

kubectl get pods -n k8ssandra-operator -l app.kubernetes.io/name=cassandra -o wide >> "$LOG_FILE" 2>&1

log "Waiting for Cassandra pod my-k8ssandra-cluster-dc1-default-sts-0 to be Ready..."
ATTEMPTS=0
MAX_ATTEMPTS=30
while true; do
  READY=$(kubectl get pod my-k8ssandra-cluster-dc1-default-sts-0 -n k8ssandra-operator -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null)
  if [ "$READY" = "true" ]; then
    break
  fi
  if [ "$ATTEMPTS" -ge "$MAX_ATTEMPTS" ]; then
    log "Timeout waiting for Cassandra pod to be ready"
    exit 1
  fi
  sleep 10
  ((ATTEMPTS++))
done

log "Fetching Cassandra superuser credentials..."
CASSANDRA_USERNAME=$(kubectl get secret my-k8ssandra-cluster-superuser \
  -n k8ssandra-operator \
  -o jsonpath="{.data.username}" | base64 -d)

CASSANDRA_PASSWORD=$(kubectl get secret my-k8ssandra-cluster-superuser \
  -n k8ssandra-operator \
  -o jsonpath="{.data.password}" | base64 -d)

log "Checking when cqlsh responds successfully..."
ATTEMPTS=0
MAX_ATTEMPTS=30
while true; do
  kubectl exec -n k8ssandra-operator my-k8ssandra-cluster-dc1-default-sts-0 -- \
    cqlsh -u "$CASSANDRA_USERNAME" -p "$CASSANDRA_PASSWORD" -e "SELECT release_version FROM system.local;" > /dev/null 2>&1 && break

  if [ "$ATTEMPTS" -ge "$MAX_ATTEMPTS" ]; then
    log "Timeout waiting for cqlsh to respond"
    exit 1
  fi
  sleep 10
  ((ATTEMPTS++))
done

log "Creating keyspace, table, and inserting test data..."
kubectl exec -n k8ssandra-operator my-k8ssandra-cluster-dc1-default-sts-0 -- \
  cqlsh -u "$CASSANDRA_USERNAME" -p "$CASSANDRA_PASSWORD" -e "
CREATE KEYSPACE IF NOT EXISTS testks WITH replication = {
  'class': 'SimpleStrategy',
  'replication_factor': 2
};

USE testks;

CREATE TABLE IF NOT EXISTS users (
  id int PRIMARY KEY,
  name text,
  email text
);

INSERT INTO users (id, name, email) VALUES (1, 'Alice', 'alice@example.com');
INSERT INTO users (id, name, email) VALUES (2, 'Bob', 'bob@example.com');
INSERT INTO users (id, name, email) VALUES (3, 'Charlie', 'charlie@example.com');
" >> "$LOG_FILE" 2>&1

log "Verifying inserted data..."
kubectl exec -i -n k8ssandra-operator my-k8ssandra-cluster-dc1-default-sts-0 -- \
  cqlsh -u "$CASSANDRA_USERNAME" -p "$CASSANDRA_PASSWORD" <<EOF >> "$LOG_FILE" 2>&1
USE testks;
SELECT * FROM users;
EOF

log "Cassandra schema and test data creation complete."

log "Creating spark namespace..."
kubectl create namespace spark >> "$LOG_FILE" 2>&1 || true

log "Creating Cassandra read script with actual password..."
mkdir -p /root/scripts
cat <<EOF > /root/scripts/cassandra_read.py
from pyspark.sql import SparkSession
import warnings
warnings.filterwarnings("ignore")


spark = SparkSession.builder \\
    .appName("ReadFromCassandra") \\
    .config("spark.cassandra.connection.host", "my-k8ssandra-cluster-dc1-service.k8ssandra-operator.svc.cluster.local") \\
    .config("spark.cassandra.auth.username", "my-k8ssandra-cluster-superuser") \\
    .config("spark.cassandra.auth.password", "$CASSANDRA_PASSWORD") \\
    .getOrCreate()

spark.sparkContext.setLogLevel("WARN")

df = spark.read \\
    .format("org.apache.spark.sql.cassandra") \\
    .options(table="users", keyspace="testks") \\
    .load()

df.show(truncate=False)
EOF

log "Creating ConfigMap for cassandra_read.py..."
kubectl create configmap spark-read-script --from-file=/root/scripts/cassandra_read.py -n spark >> "$LOG_FILE" 2>&1

log "Writing Spark manifests to /root/manifests/"
mkdir -p /root/manifests

cat <<EOF > /root/manifests/spark-master.yaml
apiVersion: v1
kind: Pod
metadata:
  name: spark-master
  namespace: spark
  labels:
    name: spark-master
spec:
  containers:
  - name: master
    image: bitnami/spark:3.3.2
    command: ["/opt/bitnami/spark/bin/spark-class"]
    args: ["org.apache.spark.deploy.master.Master"]
    env:
    - name: SPARK_MASTER_PORT
      value: "7077"
    - name: SPARK_MASTER_WEBUI_PORT
      value: "8080"
    ports:
    - containerPort: 7077
      name: spark
    - containerPort: 8080
      name: webui
  nodeSelector:
    spark-locality: "true"
EOF

cat <<EOF > /root/manifests/spark-master-svc.yaml
apiVersion: v1
kind: Service
metadata:
  name: spark-master
  namespace: spark
spec:
  selector:
    name: spark-master
  ports:
    - name: spark
      port: 7077
      targetPort: 7077
    - name: webui
      port: 8080
      targetPort: 8080
EOF

for i in 1 2; do
cat <<EOF > /root/manifests/spark-worker-$i.yaml
apiVersion: v1
kind: Pod
metadata:
  name: spark-worker-$i
  namespace: spark
  labels:
    role: spark-worker
spec:
  affinity:
    podAntiAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        - labelSelector:
            matchExpressions:
              - key: role
                operator: In
                values: ["spark-worker"]
          topologyKey: "kubernetes.io/hostname"
  containers:
  - name: spark-worker
    image: bitnami/spark:3.3.2
    command: ["/opt/bitnami/spark/bin/spark-class"]
    args: ["org.apache.spark.deploy.worker.Worker", "spark://spark-master:7077"]
    ports:
    - containerPort: 7078
  nodeSelector:
    spark-locality: "true"
EOF
done

log "Deploying Spark master, service, and workers..."
kubectl apply -f /root/manifests/spark-master.yaml >> "$LOG_FILE" 2>&1
kubectl apply -f /root/manifests/spark-master-svc.yaml >> "$LOG_FILE" 2>&1
kubectl apply -f /root/manifests/spark-worker-1.yaml >> "$LOG_FILE" 2>&1
kubectl apply -f /root/manifests/spark-worker-2.yaml >> "$LOG_FILE" 2>&1

log "Creating Spark read job manifest..."
cat <<EOF > /root/manifests/spark-read.yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: spark-read-cassandra
  namespace: spark
spec:
  template:
    spec:
      nodeSelector:
        spark-locality: "true"
      containers:
      - name: spark-read
        image: bitnami/spark:3.3.2-debian-11-r0
        command: ["/opt/bitnami/spark/bin/spark-submit"]
        args:
          - "--conf"
          - "spark.jars.packages=com.datastax.spark:spark-cassandra-connector_2.12:3.3.0"
          - "--conf"
          - "spark.driver.extraJavaOptions=-Divy.cache.dir=/tmp/.ivy2 -Divy.home=/tmp/.ivy2"
          - "--conf"
          - "spark.executor.extraJavaOptions=-Divy.cache.dir=/tmp/.ivy2 -Divy.home=/tmp/.ivy2"
          - "/scripts/cassandra_read.py"
        volumeMounts:
          - name: script-volume
            mountPath: /scripts
      restartPolicy: Never
      volumes:
        - name: script-volume
          configMap:
            name: spark-read-script
EOF

log "Deploying Spark read job..."
kubectl delete job spark-read-cassandra -n spark --ignore-not-found >> "$LOG_FILE" 2>&1
kubectl apply -f /root/manifests/spark-read.yaml >> "$LOG_FILE" 2>&1

# Mark cloud-init as complete

log "Cloud-init complete."
