/**
 * Kong API Gateway Analytics Service
 *
 * Production-grade log aggregation and analytics for Settlement and Custody Engine:
 * - Real-time log ingestion from Kong HTTP-Log plugin
 * - Metrics calculation (requests, latency, errors)
 * - Time-series aggregation
 * - Alert generation
 * - Export to external systems (DataDog, New Relic, etc.)
 *
 * @module Analytics
 */

const http = require('http');
const { EventEmitter } = require('events');

// ============================================================================
// Configuration
// ============================================================================

const CONFIG = {
  port: process.env.PORT || 8080,
  maxLogSize: parseInt(process.env.MAX_LOG_SIZE) || 10000,
  aggregationInterval: parseInt(process.env.AGGREGATION_INTERVAL) || 60000, // 1 minute
  alertThresholds: {
    errorRate: parseFloat(process.env.ERROR_RATE_THRESHOLD) || 0.05, // 5%
    p99Latency: parseInt(process.env.P99_LATENCY_THRESHOLD) || 5000, // 5 seconds
    requestsPerMinute: parseInt(process.env.RPM_THRESHOLD) || 10000,
  },
};

// ============================================================================
// In-Memory Storage (Production would use Redis/TimescaleDB)
// ============================================================================

class MetricsStore {
  constructor(maxSize = CONFIG.maxLogSize) {
    this.logs = [];
    this.maxSize = maxSize;
    this.metrics = {
      total_requests: 0,
      successful_requests: 0,
      failed_requests: 0,
      total_latency: 0,
      latencies: [],
      requests_by_service: {},
      requests_by_consumer: {},
      requests_by_status: {},
      errors_by_type: {},
      bandwidth: {
        ingress: 0,
        egress: 0,
      },
    };
    this.timeSeriesData = [];
  }

  addLog(logEntry) {
    this.logs.push(logEntry);

    // Maintain max size (circular buffer)
    if (this.logs.length > this.maxSize) {
      this.logs.shift();
    }

    // Update metrics
    this.updateMetrics(logEntry);
  }

  updateMetrics(log) {
    this.metrics.total_requests++;

    const statusCode = log.response?.status || log.upstream_status || 0;

    // Track success/failure
    if (statusCode >= 200 && statusCode < 400) {
      this.metrics.successful_requests++;
    } else {
      this.metrics.failed_requests++;
    }

    // Track by status code
    this.metrics.requests_by_status[statusCode] =
      (this.metrics.requests_by_status[statusCode] || 0) + 1;

    // Track latency
    const latency = log.latencies?.request || log.request_latency || 0;
    this.metrics.total_latency += latency;
    this.metrics.latencies.push(latency);

    // Keep latencies array manageable
    if (this.metrics.latencies.length > 10000) {
      this.metrics.latencies = this.metrics.latencies.slice(-10000);
    }

    // Track by service
    const service = log.service?.name || log.service_name || 'unknown';
    this.metrics.requests_by_service[service] =
      (this.metrics.requests_by_service[service] || 0) + 1;

    // Track by consumer
    const consumer = log.authenticated_entity?.consumer_id?.username ||
      log.consumer?.username || 'anonymous';
    this.metrics.requests_by_consumer[consumer] =
      (this.metrics.requests_by_consumer[consumer] || 0) + 1;

    // Track bandwidth
    const requestSize = parseInt(log.request?.size || 0);
    const responseSize = parseInt(log.response?.size || 0);
    this.metrics.bandwidth.ingress += requestSize;
    this.metrics.bandwidth.egress += responseSize;

    // Track errors
    if (statusCode >= 400) {
      const errorType = this.categorizeError(statusCode);
      this.metrics.errors_by_type[errorType] =
        (this.metrics.errors_by_type[errorType] || 0) + 1;
    }
  }

  categorizeError(statusCode) {
    if (statusCode === 400) return 'bad_request';
    if (statusCode === 401) return 'unauthorized';
    if (statusCode === 403) return 'forbidden';
    if (statusCode === 404) return 'not_found';
    if (statusCode === 429) return 'rate_limited';
    if (statusCode >= 500 && statusCode < 600) return 'server_error';
    return 'other';
  }

  calculatePercentile(percentile) {
    if (this.metrics.latencies.length === 0) return 0;

    const sorted = [...this.metrics.latencies].sort((a, b) => a - b);
    const index = Math.ceil((percentile / 100) * sorted.length) - 1;
    return sorted[Math.max(0, index)];
  }

  getAggregatedMetrics() {
    const totalRequests = this.metrics.total_requests;
    const errorRate =
      totalRequests > 0
        ? this.metrics.failed_requests / totalRequests
        : 0;

    return {
      summary: {
        total_requests: totalRequests,
        successful_requests: this.metrics.successful_requests,
        failed_requests: this.metrics.failed_requests,
        error_rate: errorRate,
        avg_latency:
          totalRequests > 0
            ? this.metrics.total_latency / totalRequests
            : 0,
        p50_latency: this.calculatePercentile(50),
        p95_latency: this.calculatePercentile(95),
        p99_latency: this.calculatePercentile(99),
        max_latency: Math.max(...this.metrics.latencies, 0),
        min_latency: Math.min(...this.metrics.latencies, Infinity),
      },
      by_service: this.metrics.requests_by_service,
      by_consumer: this.metrics.requests_by_consumer,
      by_status: this.metrics.requests_by_status,
      errors: this.metrics.errors_by_type,
      bandwidth: {
        ingress_bytes: this.metrics.bandwidth.ingress,
        egress_bytes: this.metrics.bandwidth.egress,
        ingress_mb: (this.metrics.bandwidth.ingress / (1024 * 1024)).toFixed(2),
        egress_mb: (this.metrics.bandwidth.egress / (1024 * 1024)).toFixed(2),
      },
    };
  }

  getRecentLogs(count = 100) {
    return this.logs.slice(-count);
  }

  reset() {
    this.logs = [];
    this.metrics = {
      total_requests: 0,
      successful_requests: 0,
      failed_requests: 0,
      total_latency: 0,
      latencies: [],
      requests_by_service: {},
      requests_by_consumer: {},
      requests_by_status: {},
      errors_by_type: {},
      bandwidth: {
        ingress: 0,
        egress: 0,
      },
    };
  }
}

// ============================================================================
// Alert Manager
// ============================================================================

class AlertManager extends EventEmitter {
  constructor(thresholds) {
    super();
    this.thresholds = thresholds;
    this.activeAlerts = new Map();
    this.alertHistory = [];
  }

  checkMetrics(metrics) {
    const alerts = [];

    // Check error rate
    if (metrics.summary.error_rate > this.thresholds.errorRate) {
      alerts.push(this.createAlert(
        'HIGH_ERROR_RATE',
        'CRITICAL',
        `Error rate ${(metrics.summary.error_rate * 100).toFixed(2)}% exceeds threshold ${this.thresholds.errorRate * 100}%`,
        { current: metrics.summary.error_rate, threshold: this.thresholds.errorRate }
      ));
    }

    // Check p99 latency
    if (metrics.summary.p99_latency > this.thresholds.p99Latency) {
      alerts.push(this.createAlert(
        'HIGH_LATENCY',
        'WARNING',
        `P99 latency ${metrics.summary.p99_latency}ms exceeds threshold ${this.thresholds.p99Latency}ms`,
        { current: metrics.summary.p99_latency, threshold: this.thresholds.p99Latency }
      ));
    }

    // Check rate limiting (too many 429s)
    const rateLimitedCount = metrics.by_status[429] || 0;
    const rateLimitRatio = metrics.summary.total_requests > 0
      ? rateLimitedCount / metrics.summary.total_requests
      : 0;

    if (rateLimitRatio > 0.1) { // More than 10% rate limited
      alerts.push(this.createAlert(
        'EXCESSIVE_RATE_LIMITING',
        'WARNING',
        `${(rateLimitRatio * 100).toFixed(2)}% of requests are being rate limited`,
        { rate_limited_count: rateLimitedCount, ratio: rateLimitRatio }
      ));
    }

    // Check server errors
    const serverErrors = metrics.errors.server_error || 0;
    if (serverErrors > 10) {
      alerts.push(this.createAlert(
        'SERVER_ERRORS',
        'CRITICAL',
        `${serverErrors} server errors detected`,
        { count: serverErrors }
      ));
    }

    // Emit and store alerts
    for (const alert of alerts) {
      this.emit('alert', alert);
      this.activeAlerts.set(alert.id, alert);
      this.alertHistory.push(alert);
    }

    // Clean up old alerts
    this.cleanupAlerts();

    return alerts;
  }

  createAlert(type, severity, message, details) {
    return {
      id: `${type}-${Date.now()}`,
      type,
      severity,
      message,
      details,
      timestamp: new Date().toISOString(),
      acknowledged: false,
    };
  }

  acknowledgeAlert(alertId) {
    if (this.activeAlerts.has(alertId)) {
      const alert = this.activeAlerts.get(alertId);
      alert.acknowledged = true;
      alert.acknowledgedAt = new Date().toISOString();
      this.emit('alertAcknowledged', alert);
      return true;
    }
    return false;
  }

  cleanupAlerts() {
    const maxAge = 24 * 60 * 60 * 1000; // 24 hours
    const cutoff = Date.now() - maxAge;

    for (const [id, alert] of this.activeAlerts.entries()) {
      if (new Date(alert.timestamp).getTime() < cutoff && alert.acknowledged) {
        this.activeAlerts.delete(id);
      }
    }

    // Keep only last 1000 alerts in history
    if (this.alertHistory.length > 1000) {
      this.alertHistory = this.alertHistory.slice(-1000);
    }
  }

  getActiveAlerts() {
    return Array.from(this.activeAlerts.values());
  }

  getAlertHistory(count = 100) {
    return this.alertHistory.slice(-count);
  }
}

// ============================================================================
// HTTP Server
// ============================================================================

const metricsStore = new MetricsStore();
const alertManager = new AlertManager(CONFIG.alertThresholds);

// Log alerts to console
alertManager.on('alert', (alert) => {
  console.log(`[ALERT] ${alert.severity}: ${alert.message}`);
});

// Create HTTP server
const server = http.createServer((req, res) => {
  const url = new URL(req.url, `http://${req.headers.host}`);

  // CORS headers
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'GET, POST, PUT, DELETE, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type, Authorization');

  if (req.method === 'OPTIONS') {
    res.writeHead(204);
    res.end();
    return;
  }

  // Route handlers
  if (req.method === 'POST' && url.pathname === '/logs') {
    handleLogIngestion(req, res);
  } else if (req.method === 'GET' && url.pathname === '/metrics') {
    handleMetricsRequest(req, res);
  } else if (req.method === 'GET' && url.pathname === '/logs') {
    handleLogsRequest(req, res, url);
  } else if (req.method === 'GET' && url.pathname === '/alerts') {
    handleAlertsRequest(req, res);
  } else if (req.method === 'POST' && url.pathname.startsWith('/alerts/')) {
    handleAlertAcknowledge(req, res, url);
  } else if (req.method === 'GET' && url.pathname === '/health') {
    handleHealthCheck(req, res);
  } else if (req.method === 'POST' && url.pathname === '/reset') {
    handleReset(req, res);
  } else if (req.method === 'GET' && url.pathname === '/prometheus') {
    handlePrometheusMetrics(req, res);
  } else {
    res.writeHead(404, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ error: 'Not Found' }));
  }
});

// Log ingestion from Kong HTTP-Log plugin
function handleLogIngestion(req, res) {
  let body = '';

  req.on('data', (chunk) => {
    body += chunk.toString();

    // Prevent memory exhaustion
    if (body.length > 10 * 1024 * 1024) { // 10MB limit
      res.writeHead(413, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: 'Payload too large' }));
      req.destroy();
    }
  });

  req.on('end', () => {
    try {
      const logEntry = JSON.parse(body);

      // Handle batch or single log
      if (Array.isArray(logEntry)) {
        for (const entry of logEntry) {
          metricsStore.addLog(entry);
        }
      } else {
        metricsStore.addLog(logEntry);
      }

      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ status: 'received' }));
    } catch (error) {
      console.error('Failed to parse log entry:', error.message);
      res.writeHead(400, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: 'Invalid JSON' }));
    }
  });

  req.on('error', (error) => {
    console.error('Request error:', error.message);
    res.writeHead(500, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ error: 'Internal server error' }));
  });
}

// Metrics endpoint
function handleMetricsRequest(req, res) {
  const metrics = metricsStore.getAggregatedMetrics();

  // Check for alerts
  const alerts = alertManager.checkMetrics(metrics);

  res.writeHead(200, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify({
    ...metrics,
    alerts: alerts.length > 0 ? alerts : [],
    timestamp: new Date().toISOString(),
  }));
}

// Logs endpoint
function handleLogsRequest(req, res, url) {
  const count = parseInt(url.searchParams.get('count')) || 100;
  const logs = metricsStore.getRecentLogs(count);

  res.writeHead(200, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify({
    count: logs.length,
    logs,
  }));
}

// Alerts endpoint
function handleAlertsRequest(req, res) {
  const activeAlerts = alertManager.getActiveAlerts();
  const history = alertManager.getAlertHistory(50);

  res.writeHead(200, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify({
    active: activeAlerts,
    history,
  }));
}

// Alert acknowledge
function handleAlertAcknowledge(req, res, url) {
  const alertId = url.pathname.split('/')[2];

  if (alertManager.acknowledgeAlert(alertId)) {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ status: 'acknowledged', alertId }));
  } else {
    res.writeHead(404, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ error: 'Alert not found' }));
  }
}

// Health check
function handleHealthCheck(req, res) {
  res.writeHead(200, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify({
    status: 'healthy',
    uptime: process.uptime(),
    memory: process.memoryUsage(),
    timestamp: new Date().toISOString(),
  }));
}

// Reset metrics
function handleReset(req, res) {
  metricsStore.reset();
  res.writeHead(200, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify({ status: 'reset' }));
}

// Prometheus-compatible metrics
function handlePrometheusMetrics(req, res) {
  const metrics = metricsStore.getAggregatedMetrics();

  const prometheusOutput = `
# HELP kong_requests_total Total number of requests
# TYPE kong_requests_total counter
kong_requests_total ${metrics.summary.total_requests}

# HELP kong_requests_successful_total Total successful requests
# TYPE kong_requests_successful_total counter
kong_requests_successful_total ${metrics.summary.successful_requests}

# HELP kong_requests_failed_total Total failed requests
# TYPE kong_requests_failed_total counter
kong_requests_failed_total ${metrics.summary.failed_requests}

# HELP kong_error_rate Current error rate
# TYPE kong_error_rate gauge
kong_error_rate ${metrics.summary.error_rate}

# HELP kong_latency_p50 P50 latency in milliseconds
# TYPE kong_latency_p50 gauge
kong_latency_p50 ${metrics.summary.p50_latency}

# HELP kong_latency_p95 P95 latency in milliseconds
# TYPE kong_latency_p95 gauge
kong_latency_p95 ${metrics.summary.p95_latency}

# HELP kong_latency_p99 P99 latency in milliseconds
# TYPE kong_latency_p99 gauge
kong_latency_p99 ${metrics.summary.p99_latency}

# HELP kong_bandwidth_ingress_bytes Total ingress bandwidth
# TYPE kong_bandwidth_ingress_bytes counter
kong_bandwidth_ingress_bytes ${metrics.bandwidth.ingress_bytes}

# HELP kong_bandwidth_egress_bytes Total egress bandwidth
# TYPE kong_bandwidth_egress_bytes counter
kong_bandwidth_egress_bytes ${metrics.bandwidth.egress_bytes}
`.trim();

  res.writeHead(200, { 'Content-Type': 'text/plain' });
  res.end(prometheusOutput);
}

// Start server
server.listen(CONFIG.port, () => {
  console.log(`Analytics server running on port ${CONFIG.port}`);
  console.log(`Configuration: ${JSON.stringify(CONFIG, null, 2)}`);
});

// Graceful shutdown
process.on('SIGTERM', () => {
  console.log('SIGTERM signal received: closing HTTP server');
  server.close(() => {
    console.log('HTTP server closed');
    process.exit(0);
  });
});

process.on('SIGINT', () => {
  console.log('SIGINT signal received: closing HTTP server');
  server.close(() => {
    console.log('HTTP server closed');
    process.exit(0);
  });
});
