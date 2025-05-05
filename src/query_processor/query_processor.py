"""
Lambda function to process queries and retrieve relevant documents using RAG.
"""
import os
import json
import boto3
import logging
import psycopg2
from typing import List, Dict, Any
from decimal import Decimal
from google import genai
from google.genai import types

# Logger setup
logger = logging.getLogger()
logger.setLevel(logging.INFO)

# AWS clients
s3_client = boto3.client('s3')
dynamodb = boto3.resource('dynamodb')
secretsmanager = boto3.client('secretsmanager')

# Environment variables
DOCUMENTS_BUCKET = os.environ.get('DOCUMENTS_BUCKET')
METADATA_TABLE = os.environ.get('METADATA_TABLE')
STAGE = os.environ.get('STAGE')
DB_SECRET_ARN = os.environ.get('DB_SECRET_ARN')
GEMINI_SECRET_NAME = os.environ.get('GEMINI_SECRET_NAME')
GEMINI_MODEL = os.environ.get('GEMINI_MODEL')
GEMINI_EMBEDDING_MODEL = os.environ.get('GEMINI_EMBEDDING_MODEL')
TEMPERATURE = float(os.environ.get('TEMPERATURE'))
MAX_OUTPUT_TOKENS = int(os.environ.get('MAX_OUTPUT_TOKENS'))
TOP_K = int(os.environ.get('TOP_K'))
TOP_P = float(os.environ.get('TOP_P'))

# Get Gemini API key from Secrets Manager
def get_gemini_api_key():
    try:
        response = secretsmanager.get_secret_value(SecretId=GEMINI_SECRET_NAME)
        return json.loads(response['SecretString'])['GEMINI_API_KEY']
    except Exception as e:
        logger.error(f"Error fetching Gemini API key: {str(e)}")
        raise

# Gemini client
try:
    GEMINI_API_KEY = get_gemini_api_key()
    client = genai.Client(api_key=GEMINI_API_KEY)
except Exception as e:
    logger.error(f"Error configuring Gemini API client: {str(e)}")
    raise

# Convert Decimal in DynamoDB
class DecimalEncoder(json.JSONEncoder):
    def default(self, o):
        if isinstance(o, Decimal):
            return float(o)
        return super().default(o)

# Embed a query using Gemini embedding model
def embed_query(text: str) -> List[float]:
    try:
        result = client.models.embed_content(
            model=GEMINI_EMBEDDING_MODEL,
            contents=text,
            config=types.EmbedContentConfig(task_type="SEMANTIC_SIMILARITY")
        )
        return list(result.embeddings[0].values)
    except Exception as e:
        logger.error(f"Error generating embedding: {str(e)}")
        return [0.0] * 768

# Embed a list of documents
def embed_documents(texts: List[str]) -> List[List[float]]:
    return [embed_query(text) for text in texts]

# Get RDS credentials from Secrets Manager
def get_postgres_credentials():
    try:
        response = secretsmanager.get_secret_value(SecretId=DB_SECRET_ARN)
        return json.loads(response['SecretString'])
    except Exception as e:
        logger.error(f"Error fetching DB credentials: {str(e)}")
        raise

# PostgreSQL connection
def get_postgres_connection(creds):
    return psycopg2.connect(
        host=creds['host'],
        port=creds['port'],
        user=creds['username'],
        password=creds['password'],
        dbname=creds['dbname']
    )


# Vector similarity search using pgvector
def similarity_search(query_embedding: List[float], user_id: str, limit: int = 5) -> List[Dict[str, Any]]:
    credentials = get_postgres_credentials()
    conn = get_postgres_connection(credentials)

    try:
        cursor = conn.cursor()

        # Manually convert the Python list to PostgreSQL vector string format
        vector_str = '[' + ','.join([str(x) for x in query_embedding]) + ']'

        cursor.execute(f"""
            SELECT 
                c.chunk_id,
                c.document_id,
                c.user_id,
                c.content,
                c.metadata,
                d.file_name,
                1 - (c.embedding <=> '{vector_str}'::vector) AS similarity_score
            FROM 
                chunks c
            JOIN 
                documents d ON c.document_id = d.document_id
            WHERE 
                c.user_id = %s
            ORDER BY 
                c.embedding <=> '{vector_str}'::vector
            LIMIT %s
        """, (user_id, limit))

        rows = cursor.fetchall()
        results = []
        for row in rows:
            chunk_id, document_id, user_id, content, metadata, file_name, similarity_score = row
            results.append({
                'chunk_id': chunk_id,
                'document_id': document_id,
                'user_id': user_id,
                'content': content,
                'metadata': metadata,
                'file_name': file_name,
                'similarity_score': float(similarity_score)
            })

        return results

    except Exception as e:
        logger.error(f"Similarity search failed: {str(e)}")
        raise e
    finally:
        cursor.close()
        conn.close()


# Generate a response from Gemini using relevant context
def generate_response(query: str, relevant_chunks: List[Dict[str, Any]]) -> str:
    context = "\n\n".join([f"Document: {c['file_name']}\nContent: {c['content']}" for c in relevant_chunks])
    prompt = f"""
    Answer the following question based on the provided context.
    If the answer is not in the context, say "I don't have enough information."

    Context:
    {context}

    Question: {query}

    Answer:
    """
    try:
        config = types.GenerateContentConfig(
            temperature=TEMPERATURE,
            top_p=TOP_P,
            top_k=TOP_K,
            max_output_tokens=MAX_OUTPUT_TOKENS,
            response_mime_type='application/json'
        )
        result = client.models.generate_content(
            model=GEMINI_MODEL,
            contents=prompt,
            config=config
        )
        return result.text
    except Exception as e:
        logger.error(f"Failed to generate response: {str(e)}")
        return "Sorry, I couldn't generate a response. Please try again later."

# Lambda handler
def handler(event, context):
    logger.info(f"Received event: {json.dumps(event)}")
    try:
         # Extract body from the request for API Gateway calls
        body = {}
        if 'body' in event:
            if isinstance(event.get('body'), str) and event.get('body'):
                try:
                    body = json.loads(event['body'])
                except json.JSONDecodeError:
                    body = {}
            elif isinstance(event.get('body'), dict):
                body = event.get('body')
                
        # Check if this is a health check request
        if event.get('action') == 'healthcheck' or body.get('action') == 'healthcheck':
            return {
                'statusCode': 200,
                'headers': {
                    'Content-Type': 'application/json',
                    'Access-Control-Allow-Origin': '*'
                },
                'body': json.dumps({
                    'message': 'Query processor is healthy',
                    'stage': STAGE
                })
            }

        query = body.get('query')
        user_id = body.get('user_id', 'system')

        if not query:
            return {
                'statusCode': 400,
                'headers': {'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*'},
                'body': json.dumps({'message': 'Query is required'})
            }

        query_embedding = embed_query(query)
        relevant_chunks = similarity_search(query_embedding, user_id)
        response = generate_response(query, relevant_chunks)

        return {
            'statusCode': 200,
            'headers': {'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*'},
            'body': json.dumps({
                'query': query,
                'response': response,
                'results': relevant_chunks,
                'count': len(relevant_chunks)
            }, cls=DecimalEncoder)
        }

    except Exception as e:
        logger.error(f"Unhandled error: {str(e)}")
        return {
            'statusCode': 500,
            'headers': {'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*'},
            'body': json.dumps({'message': f"Internal error: {str(e)}"})
        }
