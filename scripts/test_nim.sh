#!/bin/bash

# ============================================
# 🧪 Test NVIDIA NIM Deployment
# ============================================

echo "🧪 Testing NVIDIA NIM Deployment"
echo ""

# Check if pod is running
echo "📊 Checking pod status..."
POD_STATUS=$(kubectl get pods -n nim -o jsonpath='{.items[0].status.phase}' 2>/dev/null)

if [[ -z "${POD_STATUS}" ]]; then
  echo "❌ No pods found in nim namespace"
  echo "   Make sure you've deployed NIM first using: ./deploy_nim_gke.sh"
  exit 1
fi

if [[ "${POD_STATUS}" != "Running" ]]; then
  echo "⚠️  Pod is not ready yet. Current status: ${POD_STATUS}"
  echo "   Please wait for the pod to be in 'Running' state"
  echo "   Monitor with: kubectl get pods -n nim -w"
  exit 1
fi

echo "✅ Pod is running"
echo ""

# Check if port-forward is needed
echo "🔍 Checking if port-forward is active..."
if ! curl -s http://localhost:8000/v1/models > /dev/null 2>&1; then
  echo "⚠️  Port-forward not detected"
  echo ""
  echo "Please run this in a separate terminal:"
  echo "   kubectl port-forward service/my-nim-nim-llm 8000:8000 -n nim"
  echo ""
  read -p "Press Enter once port-forward is running..."
fi

# Test the models endpoint
echo ""
echo "📋 Testing /v1/models endpoint..."
MODELS_RESPONSE=$(curl -s http://localhost:8000/v1/models)
echo "${MODELS_RESPONSE}" | jq . 2>/dev/null || echo "${MODELS_RESPONSE}"

# Test chat completion
echo ""
echo "💬 Testing chat completion..."
echo "   Asking: 'What should I do for a 4 day vacation in Spain?'"
echo ""

RESPONSE=$(curl -s -X 'POST' \
  'http://localhost:8000/v1/chat/completions' \
  -H 'accept: application/json' \
  -H 'Content-Type: application/json' \
  -d '{
  "messages": [
    {
      "content": "You are a polite and respectful chatbot helping people plan a vacation.",
      "role": "system"
    },
    {
      "content": "What should I do for a 4 day vacation in Spain?",
      "role": "user"
    }
  ],
  "model": "meta/llama3-8b-instruct",
  "max_tokens": 128,
  "top_p": 1,
  "n": 1,
  "stream": false,
  "stop": "\n",
  "frequency_penalty": 0.0
}')

echo "📥 Response:"
echo "${RESPONSE}" | jq . 2>/dev/null || echo "${RESPONSE}"

# Extract just the message content
echo ""
echo "💡 AI Response:"
echo "${RESPONSE}" | jq -r '.choices[0].message.content' 2>/dev/null || echo "Could not parse response"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ Test Complete!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

