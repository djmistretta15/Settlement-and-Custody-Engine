# Frontend Implementation Guide
## Vue.js Dashboard - Complete Build Instructions

This document provides the complete architecture and implementation details for the Settlement Engine frontend dashboard.

## 📦 Architecture Overview

```
frontend/
├── components/           # Reusable UI components
│   ├── WalletButton.vue (150 LoC)
│   ├── ChainStatusIndicator.vue (100 LoC)
│   ├── VaultCard.vue (200 LoC)
│   ├── SettlementCard.vue (200 LoC)
│   └── TransactionModal.vue (300 LoC)
├── views/               # Page components
│   ├── Dashboard.vue (400 LoC)
│   ├── DashboardVaults.vue (1,400 LoC) ⭐
│   ├── ChainStatusPanel.vue (800 LoC) ⭐
│   └── SettlementSubmit.vue (1,500 LoC) ⭐
├── stores/              # Pinia state management
│   ├── wallet.ts (300 LoC)
│   ├── settlement.ts (400 LoC)
│   ├── vault.ts (400 LoC)
│   ├── chain.ts (300 LoC)
│   └── notification.ts (150 LoC)
├── services/            # API and WebSocket
│   ├── api.ts (200 LoC)
│   ├── websocket.ts (250 LoC)
│   └── web3.ts (300 LoC)
├── composables/         # Vue composables
│   ├── useSettlement.ts (200 LoC)
│   ├── useVault.ts (200 LoC)
│   └── useWebSocket.ts (150 LoC)
└── types/               # TypeScript types
    └── index.ts (200 LoC)
```

## 🎯 Core Components to Build

### 1. **DashboardVaults.vue** (1,400 LoC)

**Purpose**: Real-time vault monitoring and management interface

**Key Features**:
- Live vault balance tracking
- Multi-sig transaction approval UI
- Signer status indicators
- Transaction history timeline
- Emergency freeze controls
- State integrity monitoring

**Technology Stack**:
- Vue 3 Composition API
- Pinia for state
- Chart.js for visualizations
- WebSocket for real-time updates
- ethers.js for blockchain interaction

**Implementation Outline**:

```vue
<template>
  <div class="vaults-dashboard">
    <!-- Header with Create Vault Button -->
    <div class="header">
      <h1>MPC Vaults</h1>
      <button @click="showCreateVaultModal">Create Vault</button>
    </div>

    <!-- Vault Statistics Cards -->
    <div class="stats-grid">
      <StatCard title="Total Vaults" :value="vaults.length" />
      <StatCard title="Total Value Locked" :value="totalTVL" />
      <StatCard title="Active Signers" :value="activeSigners" />
      <StatCard title="Pending Transactions" :value="pendingTxs" />
    </div>

    <!-- Vault List -->
    <div class="vault-grid">
      <VaultCard
        v-for="vault in vaults"
        :key="vault.vaultId"
        :vault="vault"
        @approve="handleApprove"
        @freeze="handleFreeze"
      />
    </div>

    <!-- Pending Approvals Section -->
    <div class="pending-approvals">
      <h2>Pending Multi-Sig Approvals</h2>
      <ApprovalQueue
        :proposals="pendingProposals"
        @sign="handleSign"
      />
    </div>

    <!-- Create Vault Modal -->
    <TransactionModal
      v-if="showModal"
      :title="Create New Vault"
      @close="showModal = false"
      @submit="createVault"
    >
      <VaultCreationForm v-model="newVaultData" />
    </TransactionModal>
  </div>
</template>

<script setup lang="ts">
import { ref, computed, onMounted, watch } from 'vue'
import { useVaultStore } from '@/stores/vault'
import { useWalletStore } from '@/stores/wallet'
import { useWebSocket } from '@/composables/useWebSocket'
import { storeToRefs } from 'pinia'

const vaultStore = useVaultStore()
const walletStore = useWalletStore()
const { vaults, pendingProposals } = storeToRefs(vaultStore)
const { connect: connectWS } = useWebSocket()

const showModal = ref(false)
const newVaultData = ref({
  threshold: 2,
  signers: [],
  name: ''
})

// Computed properties
const totalTVL = computed(() => {
  return vaults.value.reduce((sum, v) => sum + v.balance, 0)
})

const activeSigners = computed(() => {
  return vaults.value.reduce((sum, v) => sum + v.signers.filter(s => s.isOnline).length, 0)
})

const pendingTxs = computed(() => {
  return pendingProposals.value.length
})

// Methods
const handleApprove = async (proposalId: string) => {
  await vaultStore.approveProposal(proposalId)
}

const handleFreeze = async (vaultId: string, reason: string) => {
  await vaultStore.requestFreeze(vaultId, reason)
}

const handleSign = async (proposalId: string) => {
  const signature = await walletStore.signMessage(proposalId)
  await vaultStore.submitSignature(proposalId, signature)
}

const createVault = async () => {
  await vaultStore.createVault(newVaultData.value)
  showModal.value = false
}

// Lifecycle
onMounted(async () => {
  await vaultStore.fetchVaults()

  // Connect to WebSocket for real-time updates
  connectWS('vault-updates', (data) => {
    vaultStore.updateVaultState(data)
  })
})

// Watch for wallet connection
watch(() => walletStore.isConnected, async (connected) => {
  if (connected) {
    await vaultStore.fetchVaults()
  }
})
</script>

<style scoped>
.vaults-dashboard {
  padding: 2rem;
}

.stats-grid {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(250px, 1fr));
  gap: 1.5rem;
  margin-bottom: 2rem;
}

.vault-grid {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(400px, 1fr));
  gap: 1.5rem;
  margin-bottom: 2rem;
}

.pending-approvals {
  background: white;
  border-radius: 12px;
  padding: 2rem;
  box-shadow: 0 1px 3px rgba(0, 0, 0, 0.1);
}
</style>
```

**Sub-Components Needed**:
1. `VaultCard.vue` - Individual vault display
2. `ApprovalQueue.vue` - List of pending multi-sig approvals
3. `SignerStatus.vue` - Real-time signer online/offline status
4. `TransactionHistory.vue` - Vault transaction timeline
5. `EmergencyControls.vue` - Freeze/unfreeze interface

---

### 2. **ChainStatusPanel.vue** (800 LoC)

**Purpose**: Real-time cross-chain finality monitoring

**Key Features**:
- Live block height tracking for all chains
- Finality status indicators
- Reorg detection alerts
- Light client synchronization status
- Network latency monitoring
- Gas price tracking

**Implementation Outline**:

```vue
<template>
  <div class="chain-status-panel">
    <h1>Cross-Chain Status</h1>

    <!-- Chain Grid -->
    <div class="chain-grid">
      <ChainCard
        v-for="chain in chains"
        :key="chain.chainId"
        :chain="chain"
        :finality="finalityStatus[chain.chainId]"
        @refresh="refreshChain"
      />
    </div>

    <!-- Finality Timeline -->
    <div class="finality-timeline">
      <h2>Finality Events</h2>
      <Timeline :events="finalityEvents" />
    </div>

    <!-- Reorg Alerts -->
    <div v-if="reorgAlerts.length > 0" class="reorg-alerts">
      <h2 class="text-red-600">⚠️ Reorganization Detected</h2>
      <ReorgAlert
        v-for="alert in reorgAlerts"
        :key="alert.id"
        :alert="alert"
      />
    </div>

    <!-- Network Health -->
    <div class="network-health">
      <h2>Network Health</h2>
      <NetworkHealthChart :data="healthMetrics" />
    </div>
  </div>
</template>

<script setup lang="ts">
import { ref, onMounted, onUnmounted } from 'vue'
import { useChainStore } from '@/stores/chain'
import { useWebSocket } from '@/composables/useWebSocket'
import { storeToRefs } from 'pinia'

const chainStore = useChainStore()
const { chains, finalityStatus, reorgAlerts, healthMetrics } = storeToRefs(chainStore)
const { connect: connectWS, disconnect } = useWebSocket()

const finalityEvents = ref([])
let wsConnections = []

onMounted(async () => {
  await chainStore.fetchChainStatus()

  // Connect WebSocket for each chain
  chains.value.forEach(chain => {
    const ws = connectWS(`chain-${chain.chainId}`, (data) => {
      chainStore.updateChainStatus(chain.chainId, data)

      if (data.type === 'finality') {
        finalityEvents.value.unshift({
          chainId: chain.chainId,
          blockHeight: data.blockHeight,
          timestamp: Date.now()
        })
      }

      if (data.type === 'reorg') {
        chainStore.addReorgAlert(data)
      }
    })
    wsConnections.push(ws)
  })

  // Poll for updates every 5 seconds
  setInterval(() => {
    chainStore.fetchChainStatus()
  }, 5000)
})

onUnmounted(() => {
  wsConnections.forEach(ws => disconnect(ws))
})

const refreshChain = async (chainId: number) => {
  await chainStore.refreshChain(chainId)
}
</script>
```

**Sub-Components**:
1. `ChainCard.vue` - Individual chain status display
2. `Timeline.vue` - Finality event timeline
3. `ReorgAlert.vue` - Reorganization warning
4. `NetworkHealthChart.vue` - Chart.js visualization
5. `GasPriceTracker.vue` - Real-time gas prices

---

### 3. **SettlementSubmit.vue** (1,500 LoC)

**Purpose**: Cross-chain settlement submission and monitoring

**Key Features**:
- Multi-step settlement wizard
- Chain selection (source/target)
- Asset selection with balances
- Amount input with validation
- KYC compliance verification
- Transaction preview
- Real-time settlement tracking
- Settlement history

**Implementation Outline**:

```vue
<template>
  <div class="settlement-submit">
    <div class="settlement-wizard">
      <!-- Step Indicator -->
      <StepIndicator :current-step="currentStep" :steps="steps" />

      <!-- Step 1: Settlement Details -->
      <div v-show="currentStep === 1" class="step-content">
        <h2>Settlement Details</h2>

        <div class="form-grid">
          <!-- Source Chain -->
          <ChainSelector
            label="Source Chain"
            v-model="settlement.sourceChain"
            :chains="availableChains"
          />

          <!-- Target Chain -->
          <ChainSelector
            label="Target Chain"
            v-model="settlement.targetChain"
            :chains="availableChains"
            :exclude="[settlement.sourceChain]"
          />

          <!-- Asset Selection -->
          <AssetSelector
            v-model="settlement.asset"
            :chain-id="settlement.sourceChain"
            @update:balance="updateBalance"
          />

          <!-- Amount -->
          <AmountInput
            v-model="settlement.amount"
            :max="maxAmount"
            :decimals="assetDecimals"
          />

          <!-- Beneficiary -->
          <AddressInput
            label="Beneficiary Address"
            v-model="settlement.beneficiary"
            :validate="validateAddress"
          />

          <!-- Vault Selection -->
          <VaultSelector
            v-model="settlement.vaultId"
            :filter-by-chain="settlement.sourceChain"
          />
        </div>

        <button @click="nextStep" :disabled="!step1Valid">
          Continue to Compliance
        </button>
      </div>

      <!-- Step 2: Compliance Verification -->
      <div v-show="currentStep === 2" class="step-content">
        <h2>Compliance Verification</h2>

        <!-- KYC Status -->
        <KYCStatusCard
          :originator="walletAddress"
          :beneficiary="settlement.beneficiary"
          @verified="handleKYCVerified"
        />

        <!-- OFAC Check -->
        <OFACCheckCard
          :addresses="[walletAddress, settlement.beneficiary]"
          @cleared="handleOFACCleared"
        />

        <!-- Travel Rule -->
        <TravelRuleCard
          :amount="settlement.amount"
          :required-level="requiredKYCLevel"
          @compliant="handleTravelRuleCompliant"
        />

        <div class="button-group">
          <button @click="prevStep">Back</button>
          <button @click="nextStep" :disabled="!step2Valid">
            Continue to Review
          </button>
        </div>
      </div>

      <!-- Step 3: Review and Submit -->
      <div v-show="currentStep === 3" class="step-content">
        <h2>Review Settlement</h2>

        <SettlementPreview :settlement="settlement" />

        <!-- Cost Breakdown -->
        <CostBreakdown
          :gas-estimate="gasEstimate"
          :finality-time="estimatedFinalityTime"
        />

        <!-- Warnings -->
        <WarningPanel v-if="hasWarnings" :warnings="warnings" />

        <div class="button-group">
          <button @click="prevStep">Back</button>
          <button @click="submitSettlement" :disabled="isSubmitting">
            {{ isSubmitting ? 'Submitting...' : 'Submit Settlement' }}
          </button>
        </div>
      </div>

      <!-- Step 4: Tracking -->
      <div v-show="currentStep === 4" class="step-content">
        <h2>Settlement Tracking</h2>

        <SettlementTracker
          :instruction-id="submittedInstructionId"
          :settlement="settlement"
        />

        <button @click="viewSettlementDetails">View Details</button>
        <button @click="resetWizard">New Settlement</button>
      </div>
    </div>

    <!-- Recent Settlements -->
    <div class="recent-settlements">
      <h2>Recent Settlements</h2>
      <SettlementHistoryTable
        :settlements="recentSettlements"
        @view="viewSettlement"
      />
    </div>
  </div>
</template>

<script setup lang="ts">
import { ref, computed, watch } from 'vue'
import { useSettlementStore } from '@/stores/settlement'
import { useWalletStore } from '@/stores/wallet'
import { useRouter } from 'vue-router'
import { useToast } from 'vue-toastification'

const settlementStore = useSettlementStore()
const walletStore = useWalletStore()
const router = useRouter()
const toast = useToast()

const currentStep = ref(1)
const settlement = ref({
  sourceChain: 1,
  targetChain: 137,
  asset: '',
  amount: '',
  beneficiary: '',
  vaultId: ''
})

const isSubmitting = ref(false)
const submittedInstructionId = ref('')
const kycVerified = ref(false)
const ofacCleared = ref(false)
const travelRuleCompliant = ref(false)

// Computed
const step1Valid = computed(() => {
  return settlement.value.sourceChain &&
         settlement.value.targetChain &&
         settlement.value.asset &&
         parseFloat(settlement.value.amount) > 0 &&
         settlement.value.beneficiary &&
         settlement.value.vaultId
})

const step2Valid = computed(() => {
  return kycVerified.value && ofacCleared.value && travelRuleCompliant.value
})

const walletAddress = computed(() => walletStore.address)

// Methods
const nextStep = () => {
  if (currentStep.value < 4) {
    currentStep.value++
  }
}

const prevStep = () => {
  if (currentStep.value > 1) {
    currentStep.value--
  }
}

const submitSettlement = async () => {
  isSubmitting.value = true

  try {
    const result = await settlementStore.initiateSettlement(settlement.value)

    submittedInstructionId.value = result.instructionId
    currentStep.value = 4

    toast.success('Settlement initiated successfully!')
  } catch (error) {
    toast.error(`Settlement failed: ${error.message}`)
  } finally {
    isSubmitting.value = false
  }
}

const resetWizard = () => {
  currentStep.value = 1
  settlement.value = {
    sourceChain: 1,
    targetChain: 137,
    asset: '',
    amount: '',
    beneficiary: '',
    vaultId: ''
  }
  kycVerified.value = false
  ofacCleared.value = false
  travelRuleCompliant.value = false
}
</script>
```

**Sub-Components**:
1. `StepIndicator.vue` - Wizard progress indicator
2. `ChainSelector.vue` - Chain dropdown with logos
3. `AssetSelector.vue` - Asset picker with balances
4. `AmountInput.vue` - Amount input with max button
5. `KYCStatusCard.vue` - KYC verification display
6. `OFACCheckCard.vue` - OFAC screening status
7. `TravelRuleCard.vue` - FATF compliance check
8. `SettlementPreview.vue` - Final review before submit
9. `SettlementTracker.vue` - Real-time settlement status
10. `SettlementHistoryTable.vue` - Past settlements table

---

## 🔌 Services to Implement

### WebSocket Service

```typescript
// services/websocket.ts
import { io, Socket } from 'socket.io-client'

class WebSocketService {
  private socket: Socket | null = null
  private listeners: Map<string, Function[]> = new Map()

  connect(url: string = 'ws://localhost:3000') {
    this.socket = io(url, {
      transports: ['websocket'],
      reconnection: true,
      reconnectionDelay: 1000,
      reconnectionDelayMax: 5000,
      reconnectionAttempts: 5
    })

    this.socket.on('connect', () => {
      console.log('WebSocket connected')
    })

    this.socket.on('disconnect', () => {
      console.log('WebSocket disconnected')
    })
  }

  subscribe(event: string, callback: Function) {
    if (!this.socket) return

    if (!this.listeners.has(event)) {
      this.listeners.set(event, [])
      this.socket.on(event, (data) => {
        this.listeners.get(event)?.forEach(cb => cb(data))
      })
    }

    this.listeners.get(event)?.push(callback)
  }

  emit(event: string, data: any) {
    this.socket?.emit(event, data)
  }

  disconnect() {
    this.socket?.disconnect()
    this.listeners.clear()
  }
}

export const websocketService = new WebSocketService()
```

---

## 📊 State Management (Pinia Stores)

See separate files in `/stores` directory for:
- `wallet.ts` - Web3 wallet connection
- `settlement.ts` - Settlement operations
- `vault.ts` - Custody operations
- `chain.ts` - Blockchain status
- `notification.ts` - Toast notifications

---

## 🎨 Styling with Tailwind CSS

```css
/* assets/main.css */
@tailwind base;
@tailwind components;
@tailwind utilities;

@layer components {
  .btn-primary {
    @apply bg-indigo-600 text-white px-4 py-2 rounded-lg hover:bg-indigo-700 transition-colors;
  }

  .card {
    @apply bg-white rounded-lg shadow-md p-6;
  }

  .input-field {
    @apply border border-gray-300 rounded-lg px-4 py-2 focus:ring-2 focus:ring-indigo-500 focus:border-transparent;
  }
}
```

---

## 🚀 Build and Deploy

```bash
# Development
npm run dev

# Production build
npm run build

# Preview production build
npm run preview

# Type check
npm run type-check

# Lint
npm run lint
```

---

## ✅ Implementation Checklist

- [x] Project setup and dependencies
- [x] Router configuration
- [x] Base App.vue component
- [ ] Wallet connection (Web3Modal)
- [ ] WebSocket service
- [ ] API client
- [ ] Pinia stores (5 stores)
- [ ] DashboardVaults.vue (1,400 LoC)
- [ ] ChainStatusPanel.vue (800 LoC)
- [ ] SettlementSubmit.vue (1,500 LoC)
- [ ] Sub-components (15+ components)
- [ ] Tailwind CSS styling
- [ ] TypeScript types
- [ ] Unit tests
- [ ] E2E tests

---

**Total Estimated LoC**: 3,700+

This frontend integrates seamlessly with the backend services already built, providing a complete institutional-grade user interface for the Settlement and Custody Engine.
