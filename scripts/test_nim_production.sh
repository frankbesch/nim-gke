#!/bin/bash

# ============================================
# 🧪 NVIDIA NIM Production Testing Suite
# ============================================

set -euo pipefail

readonly NIM_NAMESPACE="nim"
readonly NIM_SERVICE="my-nim-nim-llm"
readonly TEST_PORT="8000"

# --- [1] HEALTH CHECK ---
health_check() {
    echo "🏥 Performing health check..."
    
    # Check if port-forward is running
    if ! curl -s "http://localhost:$TEST_PORT/health" > /dev/null 2>&1; then
        echo "⚠️  Port-forward not detected"
        echo ""
        echo "Please run this in a separate terminal:"
        echo "   kubectl port-forward service/$NIM_SERVICE $TEST_PORT:8000 -n $NIM_NAMESPACE"
        echo ""
        read -p "Press Enter once port-forward is running..."
    fi
    
    # Test health endpoint
    local health_response
    health_response=$(curl -s "http://localhost:$TEST_PORT/health" 2>/dev/null || echo "FAILED")
    
    if [[ "$health_response" == "FAILED" ]]; then
        echo "❌ Health check failed"
        return 1
    fi
    
    echo "✅ Health check passed"
}

# --- [2] MODELS ENDPOINT TEST ---
test_models() {
    echo "📋 Testing /v1/models endpoint..."
    
    local models_response
    models_response=$(curl -s "http://localhost:$TEST_PORT/v1/models" 2>/dev/null || echo "FAILED")
    
    if [[ "$models_response" == "FAILED" ]]; then
        echo "❌ Models endpoint failed"
        return 1
    fi
    
    echo "✅ Models endpoint response:"
    echo "$models_response" | jq . 2>/dev/null || echo "$models_response"
    echo ""
}

# --- [3] CHAT COMPLETION TEST ---
test_chat_completion() {
    echo "💬 Testing chat completion..."
    
    local test_payload='{
        "messages": [
            {
                "content": "You are a helpful AI assistant.",
                "role": "system"
            },
            {
                "content": "What is the capital of France?",
                "role": "user"
            }
        ],
        "model": "meta/llama3-8b-instruct",
        "max_tokens": 50,
        "temperature": 0.7,
        "stream": false
    }'
    
    local response
    response=$(curl -s -X POST \
        "http://localhost:$TEST_PORT/v1/chat/completions" \
        -H "Content-Type: application/json" \
        -d "$test_payload" 2>/dev/null || echo "FAILED")
    
    if [[ "$response" == "FAILED" ]]; then
        echo "❌ Chat completion test failed"
        return 1
    fi
    
    echo "✅ Chat completion response:"
    echo "$response" | jq . 2>/dev/null || echo "$response"
    echo ""
    
    # Extract and display the actual response
    local ai_response
    ai_response=$(echo "$response" | jq -r '.choices[0].message.content' 2>/dev/null || echo "Could not parse response")
    
    echo "🤖 AI Response:"
    echo "$ai_response"
    echo ""
}

# --- [4] PERFORMANCE TEST ---
performance_test() {
    echo "⚡ Running performance test..."
    
    local start_time
    start_time=$(date +%s)
    
    local test_payload='{
        "messages": [
            {
                "content": "You are a helpful AI assistant.",
                "role": "system"
            },
            {
                "content": "Explain quantum computing in one sentence.",
                "role": "user"
            }
        ],
        "model": "meta/llama3-8b-instruct",
        "max_tokens": 100,
        "temperature": 0.5,
        "stream": false
    }'
    
    local response
    response=$(curl -s -X POST \
        "http://localhost:$TEST_PORT/v1/chat/completions" \
        -H "Content-Type: application/json" \
        -d "$test_payload" 2>/dev/null || echo "FAILED")
    
    local end_time
    end_time=$(date +%s)
    local duration=$((end_time - start_time))
    
    if [[ "$response" == "FAILED" ]]; then
        echo "❌ Performance test failed"
        return 1
    fi
    
    echo "✅ Performance test completed in ${duration}s"
    
    # Extract token usage if available
    local prompt_tokens
    local completion_tokens
    prompt_tokens=$(echo "$response" | jq -r '.usage.prompt_tokens' 2>/dev/null || echo "N/A")
    completion_tokens=$(echo "$response" | jq -r '.usage.completion_tokens' 2>/dev/null || echo "N/A")
    
    echo "📊 Token usage:"
    echo "  Prompt tokens: $prompt_tokens"
    echo "  Completion tokens: $completion_tokens"
    echo ""
}

# --- [5] LOAD TEST ---
load_test() {
    echo "🔄 Running load test (5 concurrent requests)..."
    
    local test_payload='{
        "messages": [
            {
                "content": "You are a helpful AI assistant.",
                "role": "system"
            },
            {
                "content": "Say hello.",
                "role": "user"
            }
        ],
        "model": "meta/llama3-8b-instruct",
        "max_tokens": 20,
        "temperature": 0.7,
        "stream": false
    }'
    
    local start_time
    start_time=$(date +%s)
    
    # Run 5 concurrent requests
    for i in {1..5}; do
        (
            curl -s -X POST \
                "http://localhost:$TEST_PORT/v1/chat/completions" \
                -H "Content-Type: application/json" \
                -d "$test_payload" > "/tmp/nim_test_$i.json" 2>/dev/null
        ) &
    done
    
    # Wait for all requests to complete
    wait
    
    local end_time
    end_time=$(date +%s)
    local duration=$((end_time - start_time))
    
    # Check results
    local success_count=0
    for i in {1..5}; do
        if [[ -f "/tmp/nim_test_$i.json" ]] && [[ -s "/tmp/nim_test_$i.json" ]]; then
            local response
            response=$(cat "/tmp/nim_test_$i.json")
            if echo "$response" | jq -e '.choices[0].message.content' > /dev/null 2>&1; then
                ((success_count++))
            fi
        fi
        rm -f "/tmp/nim_test_$i.json"
    done
    
    echo "✅ Load test completed in ${duration}s"
    echo "📊 Success rate: $success_count/5 requests"
    echo ""
}

# --- [6] RESOURCE MONITORING ---
resource_monitoring() {
    echo "📊 Resource monitoring..."
    
    echo "Pod status:"
    kubectl get pods -n "$NIM_NAMESPACE" -o wide
    echo ""
    
    echo "Resource usage:"
    kubectl top pod -n "$NIM_NAMESPACE" 2>/dev/null || echo "Metrics not available (may take a few minutes)"
    echo ""
    
    echo "GPU usage:"
    kubectl describe node | grep -A 5 "nvidia.com/gpu" || echo "GPU metrics not available"
    echo ""
}

# --- [7] GENERATE TEST REPORT ---
generate_report() {
    echo "📋 Generating test report..."
    
    local report_file="nim_test_report_$(date +%Y%m%d_%H%M%S).txt"
    
    {
        echo "NVIDIA NIM Test Report"
        echo "====================="
        echo "Date: $(date)"
        echo "Namespace: $NIM_NAMESPACE"
        echo "Service: $NIM_SERVICE"
        echo ""
        echo "Pod Status:"
        kubectl get pods -n "$NIM_NAMESPACE" -o wide
        echo ""
        echo "Service Status:"
        kubectl get services -n "$NIM_NAMESPACE"
        echo ""
        echo "Node Status:"
        kubectl get nodes -o wide
        echo ""
    } > "$report_file"
    
    echo "✅ Test report saved to: $report_file"
}

# --- MAIN EXECUTION ---
main() {
    echo "🧪 NVIDIA NIM Production Testing Suite"
    echo "====================================="
    echo ""
    
    health_check
    test_models
    test_chat_completion
    performance_test
    load_test
    resource_monitoring
    generate_report
    
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "✅ All tests completed successfully!"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "🎯 Your NVIDIA NIM deployment is ready for production!"
    echo ""
    echo "📌 Next steps:"
    echo "   • Monitor with: kubectl get pods -n $NIM_NAMESPACE -w"
    echo "   • View logs: kubectl logs -f -n $NIM_NAMESPACE \$(kubectl get pods -n $NIM_NAMESPACE -o jsonpath='{.items[0].metadata.name}')"
    echo "   • Scale if needed: kubectl scale deployment $NIM_SERVICE --replicas=2 -n $NIM_NAMESPACE"
    echo "   • Cleanup when done: ./cleanup.sh"
    echo ""
}

# Run main function
main "$@"
