/**
 * MEV Protection Module
 *
 * Production-grade Miner Extractable Value (MEV) protection:
 * - Flashbots private transaction submission
 * - Bundle atomicity guarantees
 * - MEV-Share integration
 * - Front-running and sandwich attack prevention
 *
 * @module MEVProtection
 */

export * from './flashbots';
export { default as FlashbotsClient } from './flashbots';
