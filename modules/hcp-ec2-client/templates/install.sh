#!/usr/bin/env bash
set -ex

start_service () {
  sudo mv $1.service /usr/lib/systemd/system/
  sudo systemctl enable $1.service
  sudo systemctl start $1.service
}

cd /home/ubuntu/

# Dependencies added
sudo add-apt-repository universe -y
sudo apt update -yq
sudo apt install unzip jq -qy

# Create users for consul and services
for u in consul demo sidecar; do
  sudo useradd --system --home /etc/$u.d --shell /bin/false $u
  sudo mkdir --parents /etc/$u.d /var/$u
  sudo chown --recursive $u:$u /etc/$u.d
  sudo chown --recursive $u:$u /var/$u
done

echo "${consul_service}" > consul.service
echo "${demo_service}" > demo.service
echo "${sidecar_service}" > sidecar.service

# Consul Dependencies
curl --silent -o consul.zip https://releases.hashicorp.com/consul/${consul_version}/consul_${consul_version}_linux_amd64.zip
unzip consul.zip
sudo chown consul:consul consul
sudo mv consul /usr/bin/

echo "${consul_config}" | base64 -d > client_config.temp
echo "${consul_ca}" > ca.pem
jq -n --arg token "${consul_acl_token}" '{"acl": {"tokens": {"agent": "\($token)"}}}' > client_acl.json

# Replace the relative path with the explicit path where consul will run
echo "$(jq '.ca_file = "/etc/consul.d/ca.pem"' client_config.temp )" > client_config.json
sudo mv client_config.json /etc/consul.d
sudo mv client_acl.json /etc/consul.d
sudo mv ca.pem /etc/consul.d

start_service "consul"

# install golang to run example
curl -OL https://golang.org/dl/go1.17.1.linux-amd64.tar.gz
rm -rf /usr/local/go && tar -C /usr/local -xzf go1.17.1.linux-amd64.tar.gz
export PATH=$PATH:/usr/local/go/bin

# download and install demo app
curl -OL https://github.com/hashicorp/demo-consul-101/archive/refs/heads/main.zip
unzip main.zip
cd /home/ubuntu/demo-consul-101-main/services/${demo_service_name}
if [[ -d "assets" ]]; then
  sudo /usr/local/go/bin/go install github.com/GeertJohan/go.rice/rice@latest
  sudo mv /root/go/bin/rice /usr/bin/
  /usr/bin/rice embed-go
fi
sudo /usr/local/go/bin/go build
sudo mv ${demo_service_name} /usr/bin
cd /home/ubuntu

start_service "demo"

common='{"service":{"name":"'${demo_service_name}'","port":8080,"check":{"http":"http://localhost:8080/health","method":"GET","interval":"1s","timeout":"1s"},"connect":{"sidecar_service":'
if [ "${demo_service_name}" = "counting-service" ]; then
  echo $common"{}}}}" > ${demo_service_name}.json
else
  echo $common'{"proxy":{"upstreams":[{"destination_name":"counting-service","local_bind_port":9001}]}}}}}' > ${demo_service_name}.json
fi
consul services register -token "${consul_acl_token}" ${demo_service_name}.json

# install envoy
sudo apt update
sudo apt install apt-transport-https gnupg2 curl lsb-release
curl -sL 'https://deb.dl.getenvoy.io/public/gpg.8115BA8E629CC074.key' | sudo gpg --dearmor -o /usr/share/keyrings/getenvoy-keyring.gpg
echo "deb [arch=amd64 signed-by=/usr/share/keyrings/getenvoy-keyring.gpg] https://deb.dl.getenvoy.io/public/deb/ubuntu $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/getenvoy.list
sudo apt update
sudo apt install -y getenvoy-envoy

start_service "sidecar"

echo "done"