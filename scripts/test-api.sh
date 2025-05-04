#!/bin/bash

# This script tests the RAG API by uploading a document and running a query
# Usage: ./test_api.sh <api_endpoint>

set -e

if [ "$#" -lt 1 ]; then
    echo "Usage: $0 <api_endpoint>"
    echo "Example: $0 https://abcd123.execute-api.us-east-1.amazonaws.com/dev"
    exit 1
fi

API_ENDPOINT=$1
USER_ID="test-user-$(date +%s)"
TEST_FILE="/tmp/rag_test_doc_$(date +%s).txt"

echo "Testing RAG API at: $API_ENDPOINT"
echo "Using user ID: $USER_ID"

# Create a test document
echo "Creating test document..."
cat > $TEST_FILE << EOF
Retrieval-Augmented Generation (RAG) is a technique that enhances large language models by providing them with relevant information retrieved from external knowledge sources.

RAG combines the strengths of retrieval-based systems and generative models to produce more accurate, relevant, and up-to-date responses.

The core components of a RAG system are:
1. A document store containing knowledge or information
2. An embedding model that converts text into vector representations
3. A vector database for efficient similarity search
4. A retriever that finds relevant information based on the query
5. A large language model that generates responses using the retrieved information

PostgreSQL with pgvector is an excellent choice for implementing RAG because it provides:
- A mature, reliable database system
- Vector storage and similarity search through pgvector
- ACID compliance for data integrity
- Scalability for growing document collections
- SQL interface for complex queries

RAG helps address common LLM limitations like hallucinations, knowledge cutoffs, and context window constraints by grounding responses in factual information from trusted sources.
EOF

# Base64 encode the file content
echo "Encoding file content..."
FILE_CONTENT=$(base64 $TEST_FILE)
FILE_NAME=$(basename $TEST_FILE)

# Check health endpoint
echo "Checking API health..."
HEALTH_RESPONSE=$(curl -s "$API_ENDPOINT/health")
echo "Health response: $HEALTH_RESPONSE"

# Upload the document
echo "Uploading document..."
UPLOAD_RESPONSE=$(curl -s -X POST "$API_ENDPOINT/upload" \
    -H "Content-Type: application/json" \
    -d "{
        \"file_name\": \"$FILE_NAME\",
        \"file_content\": \"$FILE_CONTENT\",
        \"mime_type\": \"text/plain\",
        \"user_id\": \"$USER_ID\"
    }")

echo "Upload response: $UPLOAD_RESPONSE"

# Extract document ID from response
DOCUMENT_ID=$(echo $UPLOAD_RESPONSE | grep -o '"document_id":"[^"]*"' | cut -d'"' -f4)

if [ -z "$DOCUMENT_ID" ]; then
    echo "Failed to extract document ID from response"
    exit 1
fi

echo "Uploaded document with ID: $DOCUMENT_ID"

# Wait for document processing
echo "Waiting for document processing (15 seconds)..."
sleep 15

# Run a query
echo "Running query..."
QUERY_RESPONSE=$(curl -s -X POST "$API_ENDPOINT/query" \
    -H "Content-Type: application/json" \
    -d "{
        \"query\": \"Why is PostgreSQL with pgvector good for RAG systems?\",
        \"user_id\": \"$USER_ID\",
        \"document_id\": \"$DOCUMENT_ID\"
    }")

echo "Query response: $QUERY_RESPONSE"

# Clean up
echo "Cleaning up..."
rm $TEST_FILE

echo "Test completed."