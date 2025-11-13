import express from 'express';
import custodyRoutes from './rest/custody.js';
import settlementRoutes from './rest/settlement.js';
import identityRoutes from './rest/identity.js';

const app = express();
const PORT = process.env.PORT || 3000;

// Middleware
app.use(express.json());
app.use(express.urlencoded({ extended: true }));

// CORS middleware
app.use((req, res, next) => {
  res.header('Access-Control-Allow-Origin', '*');
  res.header('Access-Control-Allow-Headers', 'Origin, X-Requested-With, Content-Type, Accept, Authorization');
  res.header('Access-Control-Allow-Methods', 'GET, POST, PUT, DELETE, OPTIONS');
  if (req.method === 'OPTIONS') {
    return res.sendStatus(200);
  }
  next();
});

// Request logging middleware
app.use((req, res, next) => {
  console.log(`${new Date().toISOString()} - ${req.method} ${req.path}`);
  next();
});

// Health check endpoint
app.get('/health', (req, res) => {
  res.status(200).json({ 
    status: 'healthy',
    timestamp: new Date().toISOString(),
    version: '1.0.0',
    services: {
      custody: 'operational',
      settlement: 'operational',
      identity: 'operational'
    }
  });
});

// API routes
app.use('/api/custody', custodyRoutes);
app.use('/api/settlement', settlementRoutes);
app.use('/api/identity', identityRoutes);

// Root endpoint
app.get('/', (req, res) => {
  res.json({
    name: 'Settlement and Custody Engine API',
    version: '1.0.0',
    description: 'Institutional-grade custody and cross-chain settlement API',
    endpoints: {
      custody: '/api/custody',
      settlement: '/api/settlement',
      identity: '/api/identity',
      health: '/health'
    },
    documentation: '/docs',
    timestamp: new Date().toISOString()
  });
});

// Error handling middleware
app.use((err, req, res, next) => {
  console.error('Error:', err);
  res.status(500).json({ 
    error: 'Internal server error',
    message: err.message,
    timestamp: new Date().toISOString()
  });
});

// 404 handler
app.use((req, res) => {
  res.status(404).json({ 
    error: 'Not found',
    path: req.path,
    timestamp: new Date().toISOString()
  });
});

// Start server
if (process.env.NODE_ENV !== 'test') {
  app.listen(PORT, () => {
    console.log(`Settlement and Custody Engine API running on port ${PORT}`);
    console.log(`Health check: http://localhost:${PORT}/health`);
    console.log(`API documentation: http://localhost:${PORT}/docs`);
  });
}

export default app;
