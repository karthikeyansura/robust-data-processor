package main

import (
	"context"
	"encoding/json"
	"log/slog"
	"os"
	"strings"

	"github.com/aws/aws-lambda-go/events"
	"github.com/aws/aws-lambda-go/lambda"
	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/sqs"
	"github.com/google/uuid"
)

// LogEvent is the normalized internal format for all ingested data
type LogEvent struct {
	TenantID     string `json:"tenant_id"`
	LogID        string `json:"log_id"`
	OriginalText string `json:"original_text"`
	Source       string `json:"source"`
}

var sqsClient *sqs.Client
var queueURL string

func init() {
	cfg, err := config.LoadDefaultConfig(context.TODO())
	if err != nil {
		panic("configuration error: " + err.Error())
	}
	sqsClient = sqs.NewFromConfig(cfg)
	queueURL = os.Getenv("QUEUE_URL")
}

func handler(ctx context.Context, request events.APIGatewayV2HTTPRequest) (events.APIGatewayV2HTTPResponse, error) {
	// Normalize headers (case-insensitive)
	headers := make(map[string]string)
	for k, v := range request.Headers {
		headers[strings.ToLower(k)] = v
	}

	contentType := headers["content-type"]
	var logEvent LogEvent
	logEvent.LogID = uuid.New().String()

	// Parse based on Content-Type
	if strings.Contains(contentType, "application/json") {
		logEvent.Source = "json_upload"
		var bodyMap map[string]interface{}
		if err := json.Unmarshal([]byte(request.Body), &bodyMap); err != nil {
			return events.APIGatewayV2HTTPResponse{StatusCode: 400, Body: `{"error":"Invalid JSON"}`}, nil
		}
		if tid, ok := bodyMap["tenant_id"].(string); ok {
			logEvent.TenantID = tid
		}
		if txt, ok := bodyMap["text"].(string); ok {
			logEvent.OriginalText = txt
		}
		if lid, ok := bodyMap["log_id"].(string); ok {
			logEvent.LogID = lid
		}
	} else if strings.Contains(contentType, "text/plain") {
		logEvent.Source = "text_upload"
		logEvent.TenantID = headers["x-tenant-id"]
		logEvent.OriginalText = request.Body
	} else {
		return events.APIGatewayV2HTTPResponse{StatusCode: 400, Body: `{"error":"Unsupported Content-Type"}`}, nil
	}

	// Validate tenant_id
	if logEvent.TenantID == "" {
		return events.APIGatewayV2HTTPResponse{StatusCode: 400, Body: `{"error":"Missing tenant_id"}`}, nil
	}

	// Validate text content
	if logEvent.OriginalText == "" {
		return events.APIGatewayV2HTTPResponse{StatusCode: 400, Body: `{"error":"Missing text content"}`}, nil
	}

	// Publish to SQS
	payload, _ := json.Marshal(logEvent)
	_, err := sqsClient.SendMessage(ctx, &sqs.SendMessageInput{
		MessageBody: aws.String(string(payload)),
		QueueUrl:    aws.String(queueURL),
	})

	if err != nil {
		slog.Error("Failed to enqueue message", "error", err)
		return events.APIGatewayV2HTTPResponse{StatusCode: 500, Body: `{"error":"Internal server error"}`}, nil
	}

	// Return 202 Accepted immediately (non-blocking)
	responseBody, _ := json.Marshal(map[string]string{
		"status":    "accepted",
		"log_id":    logEvent.LogID,
		"tenant_id": logEvent.TenantID,
		"message":   "Processing queued",
	})

	return events.APIGatewayV2HTTPResponse{
		StatusCode: 202,
		Headers:    map[string]string{"Content-Type": "application/json"},
		Body:       string(responseBody),
	}, nil
}

func main() {
	lambda.Start(handler)
}
