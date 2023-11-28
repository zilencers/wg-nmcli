#!/bin/bash

CONN_NAME="wg0-server"
TUNNEL_IP="10.8.0.1/24"
VIRT_IFNAME="wg0"
PORT=51820

usage() {
   echo "wg-srv.sh [OPTION] [VALUE]"
   echo " -c|--conn-name      network manager connection name"
   echo "-ip|--tunnel-ip      server tunnel ip in CIDR notation"
   echo " -p|--port           port the server should listen on"
   echo "-pk|--peer-pubkey    peer public key"
   echo " -v|--virt-ifname    virtual interface name"
   echo " -h|--help           display help information"

   exit 0
}

abnormal_exit() {
   echo "Error: $1"
   $2
   exit 1
}

parse_args() {
   while (($#))
   do
      case $1 in
	  -c|--conn-name)
	     CONN_NAME=$2
	     shift 2
	     ;;
         -ip|--tunnel-ip)
	    TUNNEL_IP=$2
	    shift 2
	    ;;
	  -p|--port)
	    PORT=$2
	    shift 2
	    ;;
	 -pk|--peer-pubkey)
	    PEER_PUBKEY=$2
	    shift 2
	    ;;
	  -v|--virt-ifname)
	    VIRT_IFNAME=$2
	    shift 2
	    ;;
      esac
   done
}

validate_args() {
   [ -n "$PEER_PUBKEY" ] && abnormal_exit "missing required argument -pk|--peer-pubkey" usage
}

install_pkg() {
   printf "Installing wireguard ..."
   dnf -y install wireguard-tools
}

genkeys() {
   umask 077; wg genkey | tee /etc/wireguard/privatekey | wg pubkey > /etc/wireguard/publickey
   PRIVATE_KEY=$(cat /etc/wireguard/privatekey)
}

create_connection() {
   # Add a NetworkManager WireGuard connection profile
   nmcli connection add type wireguard con-name $CONN_NAME ifname $VIRT_IFNAME autoconnect no

   # Set the tunnel IPv4 address and subnet mask of the server
   nmcli connection modify $CONN_NAME ipv4.method manual ipv4.addresses $TUNNEL_IP

   # Add the server’s private key to the connection profile
   nmcli connection modify $CONN_NAME wireguard.private-key "$PRIVATE_KEY"

   # Set the port for incoming WireGuard connections
   nmcli connection modify $CONN_NAME wireguard.listen-port $PORT

   # Add peer configuration
   add_peer

   # Reload the connection profile
   nmcli connection load /etc/NetworkManager/system-connections/$CONN_NAME.nmconnection

   # Configure the connection to start automatically
   nmcli connection modify $CONN_NAME autoconnect yes
   
   # Reactivate the connection
   nmcli connection up $CONN_NAME
}

add_peer() {
   local tunnel_subnet=$(echo $TUNNEL_IP | grep -oP "^\d{1,3}\.\d{1,3}\.\d{1,3}\.")
   local subnet_length=${#tunnel_subnet}
   local host=${TUNNEL_IP:subnet_length:5}

   if [ $host -le 253 ]; then
      local peer_ip="$tunnel_subnet$(expr $host + 1)"
   else
      abnormal_exit "host address out of range"
   fi

cat << EOF >> /etc/NetworkManager/system-connections/$CONN_NAME.nmconnection
[wireguard-peer.$PEER_PUBKEY]
allowed-ips=$peer_ip;
EOF
}

main() {
   parse_args $@
   install_pkg
   genkeys
   create_connection
}

main $@
