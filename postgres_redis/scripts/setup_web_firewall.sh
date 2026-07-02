#!/bin/bash

# Script to configure UFW firewall for a Traefik Web Server
# Allowed Ports: 22 (SSH), 80 (HTTP), 443 (HTTPS)
# Default Policy: Deny Incoming, Allow Outgoing

# Check if running as root
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root (sudo)"
  exit 1
fi

action="${1:-enable}"

case "$action" in
    enable)
        echo "Setting up web server firewall rules..."
        
        # 1. Set Default Policies (Secure)
        ufw default deny incoming
        ufw default allow outgoing
        
        # 2. Allow SSH (Port 22) - Critical for remote access
        echo "Allowing SSH (Port 22)..."
        ufw allow 22/tcp
        
        # 3. Allow HTTP (Port 80) - Traefik EntryPoint 'web'
        echo "Allowing HTTP (Port 80)..."
        ufw allow 80/tcp
        
        # 4. Allow HTTPS (Port 443) - Traefik EntryPoint 'websecure'
        echo "Allowing HTTPS (Port 443)..."
        ufw allow 443/tcp

        # Note: Traefik Dashboard (8080) is NOT allowed by default as per request.
        # It should ideally be accessed via a secure tunnel or reverse proxy rules, not open port.
        
        # 5. Enable UFW
        echo "Enabling UFW..."
        ufw --force enable
        
        echo "Firewall configured and enabled."
        ;;
        
    disable)
        echo "Disabling web server specific rules..."
        
        ufw delete allow 22/tcp
        ufw delete allow 80/tcp
        ufw delete allow 443/tcp
        
        echo "Rules removed. Note: UFW is still enabled. Run 'ufw disable' to turn it off completely."
        ;;
        
    status)
        echo "Current Firewall Status:"
        ufw status verbose
        ;;
        
    *)
        echo "Usage: $0 {enable|disable|status}"
        exit 1
        ;;
esac
