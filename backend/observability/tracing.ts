/**
 * Distributed Tracing with OpenTelemetry
 *
 * Production-grade observability for Settlement and Custody Engine:
 * - End-to-end request tracing across microservices
 * - Automatic instrumentation for HTTP, gRPC, databases
 * - Custom spans for business logic
 * - Context propagation (W3C Trace Context)
 * - Export to Jaeger, Zipkin, or OTLP backends
 * - Baggage for cross-service metadata
 *
 * @module Tracing
 */

import { NodeSDK } from '@opentelemetry/sdk-node';
import { getNodeAutoInstrumentations } from '@opentelemetry/auto-instrumentations-node';
import { OTLPTraceExporter } from '@opentelemetry/exporter-trace-otlp-http';
import { OTLPMetricExporter } from '@opentelemetry/exporter-metrics-otlp-http';
import { PeriodicExportingMetricReader } from '@opentelemetry/sdk-metrics';
import { Resource } from '@opentelemetry/resources';
import { SemanticResourceAttributes } from '@opentelemetry/semantic-conventions';
import {
  trace,
  context,
  SpanKind,
  SpanStatusCode,
  Span,
  Tracer,
  propagation,
  ROOT_CONTEXT,
} from '@opentelemetry/api';
import { W3CTraceContextPropagator } from '@opentelemetry/core';

// ============================================================================
// Configuration
// ============================================================================

export interface TracingConfig {
  serviceName: string;
  serviceVersion: string;
  environment: string;
  otlpEndpoint: string;
  otlpMetricsEndpoint?: string;
  samplingRatio?: number;
  enableAutoInstrumentation?: boolean;
  customAttributes?: Record<string, string>;
}

// ============================================================================
// Tracing SDK Initializer
// ============================================================================

export class TracingSDK {
  private sdk: NodeSDK;
  private tracer: Tracer;
  private config: TracingConfig;

  constructor(config: TracingConfig) {
    this.config = config;

    // Create resource with service metadata
    const resource = new Resource({
      [SemanticResourceAttributes.SERVICE_NAME]: config.serviceName,
      [SemanticResourceAttributes.SERVICE_VERSION]: config.serviceVersion,
      [SemanticResourceAttributes.DEPLOYMENT_ENVIRONMENT]: config.environment,
      ...config.customAttributes,
    });

    // Configure OTLP exporters
    const traceExporter = new OTLPTraceExporter({
      url: config.otlpEndpoint,
      headers: {},
    });

    const metricExporter = config.otlpMetricsEndpoint
      ? new OTLPMetricExporter({
          url: config.otlpMetricsEndpoint,
        })
      : undefined;

    // Initialize OpenTelemetry SDK
    this.sdk = new NodeSDK({
      resource,
      traceExporter,
      metricReader: metricExporter
        ? new PeriodicExportingMetricReader({
            exporter: metricExporter,
            exportIntervalMillis: 60000,
          })
        : undefined,
      instrumentations: config.enableAutoInstrumentation
        ? [
            getNodeAutoInstrumentations({
              '@opentelemetry/instrumentation-http': {
                ignoreIncomingPaths: ['/health', '/metrics'],
              },
              '@opentelemetry/instrumentation-express': {
                ignoreLayers: ['health-check'],
              },
              '@opentelemetry/instrumentation-pg': {
                enhancedDatabaseReporting: true,
              },
              '@opentelemetry/instrumentation-redis': {
                dbStatementSerializer: (cmdName, cmdArgs) =>
                  `${cmdName} ${cmdArgs.join(' ')}`,
              },
            }),
          ]
        : [],
    });

    // Set global propagator
    propagation.setGlobalPropagator(new W3CTraceContextPropagator());

    // Get tracer instance
    this.tracer = trace.getTracer(config.serviceName, config.serviceVersion);
  }

  start(): void {
    this.sdk.start();
    console.log(`Tracing initialized for ${this.config.serviceName}`);
  }

  async shutdown(): Promise<void> {
    await this.sdk.shutdown();
    console.log('Tracing shutdown complete');
  }

  getTracer(): Tracer {
    return this.tracer;
  }
}

// ============================================================================
// Custom Span Decorators
// ============================================================================

export function traced(spanName?: string) {
  return function (
    target: unknown,
    propertyKey: string,
    descriptor: PropertyDescriptor
  ) {
    const originalMethod = descriptor.value;
    const name = spanName || `${target?.constructor?.name}.${propertyKey}`;

    descriptor.value = async function (...args: unknown[]) {
      const tracer = trace.getTracer('settlement-engine');

      return tracer.startActiveSpan(name, async (span: Span) => {
        try {
          const result = await originalMethod.apply(this, args);
          span.setStatus({ code: SpanStatusCode.OK });
          return result;
        } catch (error) {
          span.setStatus({
            code: SpanStatusCode.ERROR,
            message: (error as Error).message,
          });
          span.recordException(error as Error);
          throw error;
        } finally {
          span.end();
        }
      });
    };

    return descriptor;
  };
}

// ============================================================================
// Settlement Engine Instrumentation
// ============================================================================

export class SettlementTracing {
  private tracer: Tracer;

  constructor() {
    this.tracer = trace.getTracer('settlement-engine');
  }

  // Trace settlement creation
  async traceSettlementCreation<T>(
    instructionId: string,
    operation: () => Promise<T>
  ): Promise<T> {
    return this.tracer.startActiveSpan(
      'settlement.create',
      {
        kind: SpanKind.PRODUCER,
        attributes: {
          'settlement.instruction_id': instructionId,
          'settlement.operation': 'create',
        },
      },
      async (span: Span) => {
        try {
          const result = await operation();
          span.setStatus({ code: SpanStatusCode.OK });
          span.setAttribute('settlement.status', 'created');
          return result;
        } catch (error) {
          span.setStatus({
            code: SpanStatusCode.ERROR,
            message: (error as Error).message,
          });
          span.recordException(error as Error);
          throw error;
        } finally {
          span.end();
        }
      }
    );
  }

  // Trace finality verification
  async traceFinalityVerification<T>(
    chainId: number,
    blockHeight: number,
    operation: () => Promise<T>
  ): Promise<T> {
    return this.tracer.startActiveSpan(
      'finality.verify',
      {
        kind: SpanKind.CLIENT,
        attributes: {
          'chain.id': chainId,
          'block.height': blockHeight,
          'finality.operation': 'verify',
        },
      },
      async (span: Span) => {
        try {
          const result = await operation();
          span.setStatus({ code: SpanStatusCode.OK });
          return result;
        } catch (error) {
          span.setStatus({ code: SpanStatusCode.ERROR });
          span.recordException(error as Error);
          throw error;
        } finally {
          span.end();
        }
      }
    );
  }

  // Trace vault operations
  async traceVaultOperation<T>(
    vaultId: string,
    operationType: 'create' | 'approve' | 'execute' | 'freeze',
    operation: () => Promise<T>
  ): Promise<T> {
    return this.tracer.startActiveSpan(
      `vault.${operationType}`,
      {
        kind: SpanKind.INTERNAL,
        attributes: {
          'vault.id': vaultId,
          'vault.operation': operationType,
        },
      },
      async (span: Span) => {
        try {
          const result = await operation();
          span.setStatus({ code: SpanStatusCode.OK });
          return result;
        } catch (error) {
          span.setStatus({ code: SpanStatusCode.ERROR });
          span.recordException(error as Error);
          throw error;
        } finally {
          span.end();
        }
      }
    );
  }

  // Trace HSM signing
  async traceHSMSigning<T>(
    keyId: string,
    operation: () => Promise<T>
  ): Promise<T> {
    return this.tracer.startActiveSpan(
      'hsm.sign',
      {
        kind: SpanKind.CLIENT,
        attributes: {
          'hsm.key_id': keyId,
          'hsm.operation': 'sign',
        },
      },
      async (span: Span) => {
        const startTime = Date.now();
        try {
          const result = await operation();
          const duration = Date.now() - startTime;
          span.setAttribute('hsm.duration_ms', duration);
          span.setStatus({ code: SpanStatusCode.OK });
          return result;
        } catch (error) {
          span.setStatus({ code: SpanStatusCode.ERROR });
          span.recordException(error as Error);
          throw error;
        } finally {
          span.end();
        }
      }
    );
  }

  // Trace ZK proof generation
  async traceZKProofGeneration<T>(
    circuitName: string,
    operation: () => Promise<T>
  ): Promise<T> {
    return this.tracer.startActiveSpan(
      'zk.generate_proof',
      {
        kind: SpanKind.INTERNAL,
        attributes: {
          'zk.circuit': circuitName,
          'zk.operation': 'generate',
        },
      },
      async (span: Span) => {
        const startTime = Date.now();
        try {
          const result = await operation();
          const duration = Date.now() - startTime;
          span.setAttribute('zk.proving_time_ms', duration);
          span.setStatus({ code: SpanStatusCode.OK });
          return result;
        } catch (error) {
          span.setStatus({ code: SpanStatusCode.ERROR });
          span.recordException(error as Error);
          throw error;
        } finally {
          span.end();
        }
      }
    );
  }

  // Add custom event to current span
  addEvent(name: string, attributes?: Record<string, unknown>): void {
    const currentSpan = trace.getActiveSpan();
    if (currentSpan) {
      currentSpan.addEvent(name, attributes);
    }
  }

  // Set attribute on current span
  setAttribute(key: string, value: string | number | boolean): void {
    const currentSpan = trace.getActiveSpan();
    if (currentSpan) {
      currentSpan.setAttribute(key, value);
    }
  }

  // Get current trace context for propagation
  getCurrentTraceContext(): Record<string, string> {
    const headers: Record<string, string> = {};
    propagation.inject(context.active(), headers);
    return headers;
  }

  // Extract trace context from incoming request
  extractTraceContext(headers: Record<string, string>): void {
    propagation.extract(ROOT_CONTEXT, headers);
  }
}

// ============================================================================
// Middleware for Express
// ============================================================================

export function tracingMiddleware(serviceName: string) {
  const tracer = trace.getTracer(serviceName);

  return (req: unknown, res: unknown, next: () => void) => {
    const request = req as { method: string; path: string; headers: Record<string, string> };
    const response = res as { statusCode: number; on: (event: string, callback: () => void) => void };

    const span = tracer.startSpan(`HTTP ${request.method} ${request.path}`, {
      kind: SpanKind.SERVER,
      attributes: {
        'http.method': request.method,
        'http.url': request.path,
        'http.user_agent': request.headers['user-agent'] || 'unknown',
      },
    });

    // Set span in context
    const activeContext = trace.setSpan(context.active(), span);

    context.with(activeContext, () => {
      // Add response handling
      response.on('finish', () => {
        span.setAttribute('http.status_code', response.statusCode);

        if (response.statusCode >= 400) {
          span.setStatus({
            code: SpanStatusCode.ERROR,
            message: `HTTP ${response.statusCode}`,
          });
        } else {
          span.setStatus({ code: SpanStatusCode.OK });
        }

        span.end();
      });

      next();
    });
  };
}

// ============================================================================
// Metrics Collection
// ============================================================================

export interface MetricLabels {
  operation: string;
  status: 'success' | 'error';
  chainId?: string;
}

export class MetricsCollector {
  private counters: Map<string, number> = new Map();
  private histograms: Map<string, number[]> = new Map();

  incrementCounter(name: string, labels: MetricLabels, value: number = 1): void {
    const key = `${name}:${JSON.stringify(labels)}`;
    const current = this.counters.get(key) || 0;
    this.counters.set(key, current + value);
  }

  recordHistogram(name: string, labels: MetricLabels, value: number): void {
    const key = `${name}:${JSON.stringify(labels)}`;
    const values = this.histograms.get(key) || [];
    values.push(value);
    this.histograms.set(key, values);
  }

  getMetrics(): Record<string, unknown> {
    return {
      counters: Object.fromEntries(this.counters),
      histograms: Object.fromEntries(
        Array.from(this.histograms.entries()).map(([key, values]) => [
          key,
          {
            count: values.length,
            sum: values.reduce((a, b) => a + b, 0),
            avg: values.reduce((a, b) => a + b, 0) / values.length,
            min: Math.min(...values),
            max: Math.max(...values),
            p50: this.percentile(values, 50),
            p95: this.percentile(values, 95),
            p99: this.percentile(values, 99),
          },
        ])
      ),
    };
  }

  private percentile(values: number[], p: number): number {
    const sorted = [...values].sort((a, b) => a - b);
    const index = Math.ceil((p / 100) * sorted.length) - 1;
    return sorted[index];
  }
}

// ============================================================================
// Example Usage
// ============================================================================

async function main() {
  console.log('Distributed Tracing Example\n');

  // Initialize tracing SDK
  const tracingSDK = new TracingSDK({
    serviceName: 'settlement-engine',
    serviceVersion: '1.0.0',
    environment: 'production',
    otlpEndpoint: 'http://localhost:4318/v1/traces',
    otlpMetricsEndpoint: 'http://localhost:4318/v1/metrics',
    samplingRatio: 1.0, // 100% sampling for demo
    enableAutoInstrumentation: true,
    customAttributes: {
      'cloud.provider': 'aws',
      'cloud.region': 'us-east-1',
    },
  });

  tracingSDK.start();

  const settlementTracing = new SettlementTracing();
  const metricsCollector = new MetricsCollector();

  console.log('Step 1: Trace settlement creation');
  await settlementTracing.traceSettlementCreation('SET-001', async () => {
    // Simulate settlement creation
    await new Promise((resolve) => setTimeout(resolve, 100));
    metricsCollector.incrementCounter('settlements_created', {
      operation: 'create',
      status: 'success',
    });
    console.log('  Settlement created: SET-001');
    return { id: 'SET-001', status: 'created' };
  });

  console.log('\nStep 2: Trace finality verification');
  await settlementTracing.traceFinalityVerification(1, 1000000, async () => {
    await new Promise((resolve) => setTimeout(resolve, 50));
    metricsCollector.recordHistogram(
      'finality_verification_duration',
      { operation: 'verify', status: 'success', chainId: '1' },
      50
    );
    console.log('  Finality verified: Chain 1, Block 1000000');
    return true;
  });

  console.log('\nStep 3: Trace vault approval');
  await settlementTracing.traceVaultOperation('VAULT-001', 'approve', async () => {
    await new Promise((resolve) => setTimeout(resolve, 75));
    console.log('  Vault approval recorded: VAULT-001');
    return { approved: true, signatures: 2 };
  });

  console.log('\nStep 4: Trace HSM signing');
  await settlementTracing.traceHSMSigning('key-12345', async () => {
    await new Promise((resolve) => setTimeout(resolve, 200));
    metricsCollector.recordHistogram(
      'hsm_signing_duration',
      { operation: 'sign', status: 'success' },
      200
    );
    console.log('  HSM signature generated');
    return Buffer.from('signature-data');
  });

  console.log('\nStep 5: Trace ZK proof generation');
  await settlementTracing.traceZKProofGeneration('finality-verifier', async () => {
    await new Promise((resolve) => setTimeout(resolve, 500));
    metricsCollector.recordHistogram(
      'zk_proof_generation',
      { operation: 'generate', status: 'success' },
      500
    );
    console.log('  ZK proof generated (500ms)');
    return { proof: 'zk-proof-data', publicSignals: [] };
  });

  console.log('\nStep 6: View collected metrics');
  const metrics = metricsCollector.getMetrics();
  console.log(JSON.stringify(metrics, null, 2));

  console.log('\n✅ Distributed tracing complete!');
  console.log('   - End-to-end request tracing');
  console.log('   - Custom spans for business logic');
  console.log('   - Context propagation (W3C Trace Context)');
  console.log('   - Metrics collection with percentiles');
  console.log('   - Export to OTLP backend (Jaeger/Zipkin)');

  await tracingSDK.shutdown();
}

// Run example if executed directly
if (require.main === module) {
  main().catch(console.error);
}
