#!/bin/bash

echo "╔════════════════════════════════════════════════════════════╗"
echo "║         📊 n8n Monitoring Dashboard                        ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""

# Check if namespace exists
if ! kubectl get namespace n8n &>/dev/null; then
  echo "❌ n8n namespace not found. Please deploy first using ./scripts/deploy.sh"
  exit 1
fi

echo "🔍 PODS STATUS:"
echo "─────────────────────────────────────────────────────────"
kubectl get pods -n n8n -o wide

echo ""
echo "📊 POD DETAILS:"
echo "─────────────────────────────────────────────────────────"
for pod in $(kubectl get pods -n n8n -o jsonpath='{.items[*].metadata.name}'); do
  echo ""
  echo "📦 $pod"
  kubectl describe pod $pod -n n8n | grep -A 5 "Status:" | head -6
  kubectl get pod $pod -n n8n -o jsonpath='  Restarts: {.status.containerStatuses[0].restartCount}' && echo ""
done

echo ""
echo "🌐 SERVICES:"
echo "─────────────────────────────────────────────────────────"
kubectl get services -n n8n

echo ""
echo "💾 PERSISTENT VOLUMES:"
echo "─────────────────────────────────────────────────────────"
kubectl get pvc -n n8n

echo ""
echo "📈 RESOURCE USAGE:"
echo "─────────────────────────────────────────────────────────"
if kubectl top pods -n n8n 2>/dev/null; then
  kubectl top nodes
else
  echo "⚠️  Metrics server not available. Install metrics server to see resource usage."
fi

echo ""
echo "🔐 EVENTS (Recent):"
echo "─────────────────────────────────────────────────────────"
kubectl get events -n n8n --sort-by='.lastTimestamp' | tail -10

echo ""
echo "🔗 ACCESS URL:"
echo "─────────────────────────────────────────────────────────"
URL=$(kubectl get service n8n-service-simple -n n8n -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)
if [ ! -z "$URL" ]; then
  echo "✅ n8n is accessible at: http://${URL}"
else
  echo "⏳ LoadBalancer URL is still pending..."
  echo "   Check with: kubectl get service n8n-service-simple -n n8n"
fi

echo ""
echo "📋 QUICK COMMANDS:"
echo "─────────────────────────────────────────────────────────"
echo "  View logs:           kubectl logs -f deployment/n8n-simple -n n8n"
echo "  Restart:             kubectl rollout restart deployment/n8n-simple -n n8n"
echo "  Scale:               kubectl scale deployment n8n-simple --replicas=2 -n n8n"
echo "  Get credentials:     kubectl get secret postgres-secret -n n8n -o yaml"
echo ""

echo "╚════════════════════════════════════════════════════════════╝"
