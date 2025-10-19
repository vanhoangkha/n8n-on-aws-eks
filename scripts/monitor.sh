#!/bin/bash

echo "📊 n8n Monitoring Dashboard"
echo "=========================="

echo "🔍 Pods Status:"
kubectl get pods -n n8n

echo ""
echo "🌐 Services:"
kubectl get services -n n8n

echo ""
echo "📈 Resource Usage:"
kubectl top pods -n n8n 2>/dev/null || echo "Metrics server not available"

echo ""
echo "🔗 n8n URL:"
kubectl get service n8n-service-simple -n n8n -o jsonpath='http://{.status.loadBalancer.ingress[0].hostname}' && echo
