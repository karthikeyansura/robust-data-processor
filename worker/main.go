package main

import (
	"context"
	"encoding/json"
	"log/slog"
	"os"
	"regexp"
	"time"

	"github.com/aws/aws-lambda-go/events"
	"github.com/aws/aws-lambda-go/lambda"
	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/dynamodb"
	"github.com/aws/aws-sdk-go-v2/service/dynamodb/types"
)

var dynamoClient *dynamodb.Client
var tableName string

// PII redaction patterns
var (
	phonePattern = regexp.MustCompile(`\b\d{3}[-.]?\d{3}[-.]?\d{4}\b`)
	ssnPattern   = regexp.MustCompile(`\b\d{3}-\d{2}-\d{4}\b`)
	emailPattern = regexp.MustCompile(`\b[\w.-]+@[\w.-]+\.\w+\b`)
)

func init() {
	cfg, err := config.LoadDefaultConfig(context.TODO())
	if err != nil {
		panic("configuration error: " + err.Error())
	}
	dynamoClient = dynamodb.NewFromConfig(cfg)
	tableName = os.Getenv("TABLE_NAME")
}

// LogEvent matches the format from ingest service
type LogEvent struct {
	TenantID     string `json:"tenant_id"`
	LogID        string `json:"log_id"`
	OriginalText string `json:"original_text"`
	Source       string `json:"source"`
}

// handler implements Partial Batch Failure pattern for crash recovery
func handler(ctx context.Context, sqsEvent events.SQSEvent) (events.SQSEventResponse, error) {
	var failures []events.SQSBatchItemFailure

	for _, message := range sqsEvent.Records {
		if err := processMessage(ctx, message); err != nil {
			slog.Error("Processing failed", "message_id", message.MessageId, "error", err)
			// Mark only THIS message as failed - others in batch succeed
			failures = append(failures, events.SQSBatchItemFailure{
				ItemIdentifier: message.MessageId,
			})
		}
	}

	return events.SQSEventResponse{BatchItemFailures: failures}, nil
}

func processMessage(ctx context.Context, message events.SQSMessage) error {
	var event LogEvent
	if err := json.Unmarshal([]byte(message.Body), &event); err != nil {
		return err
	}

	slog.Info("Processing message",
		"tenant_id", event.TenantID,
		"log_id", event.LogID,
		"text_length", len(event.OriginalText),
	)

	// SIMULATE HEAVY PROCESSING: 0.05s per character
	// Cap at 5 seconds for testing (adjust for production)
	sleepDuration := time.Duration(len(event.OriginalText)) * 50 * time.Millisecond
	if sleepDuration > 5*time.Second {
		sleepDuration = 5 * time.Second
	}
	time.Sleep(sleepDuration)

	// Redact PII from text
	modifiedData := redactPII(event.OriginalText)

	// Write to DynamoDB with tenant isolation (partition key = tenant_id)
	_, err := dynamoClient.PutItem(ctx, &dynamodb.PutItemInput{
		TableName: aws.String(tableName),
		Item: map[string]types.AttributeValue{
			"tenant_id":     &types.AttributeValueMemberS{Value: event.TenantID},
			"log_id":        &types.AttributeValueMemberS{Value: event.LogID},
			"source":        &types.AttributeValueMemberS{Value: event.Source},
			"original_text": &types.AttributeValueMemberS{Value: event.OriginalText},
			"modified_data": &types.AttributeValueMemberS{Value: modifiedData},
			"processed_at":  &types.AttributeValueMemberS{Value: time.Now().UTC().Format(time.RFC3339)},
			"status":        &types.AttributeValueMemberS{Value: "PROCESSED"},
		},
	})

	if err != nil {
		return err
	}

	slog.Info("Successfully processed", "tenant_id", event.TenantID, "log_id", event.LogID)
	return nil
}

// redactPII replaces sensitive patterns with [REDACTED]
func redactPII(text string) string {
	text = phonePattern.ReplaceAllString(text, "[REDACTED]")
	text = ssnPattern.ReplaceAllString(text, "[REDACTED]")
	text = emailPattern.ReplaceAllString(text, "[REDACTED]")
	return text
}

func main() {
	lambda.Start(handler)
}
