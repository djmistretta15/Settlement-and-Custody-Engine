<template>
  <div id="app" class="min-h-screen bg-gray-50">
    <!-- Navigation -->
    <nav class="bg-white shadow-sm border-b border-gray-200">
      <div class="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8">
        <div class="flex justify-between h-16">
          <div class="flex">
            <div class="flex-shrink-0 flex items-center">
              <h1 class="text-2xl font-bold text-indigo-600">Settlement Engine</h1>
            </div>
            <div class="hidden sm:ml-6 sm:flex sm:space-x-8">
              <router-link
                to="/"
                class="border-transparent text-gray-900 inline-flex items-center px-1 pt-1 border-b-2 text-sm font-medium hover:border-indigo-500"
              >
                Dashboard
              </router-link>
              <router-link
                to="/vaults"
                class="border-transparent text-gray-500 hover:border-gray-300 hover:text-gray-700 inline-flex items-center px-1 pt-1 border-b-2 text-sm font-medium"
              >
                Vaults
              </router-link>
              <router-link
                to="/settlements"
                class="border-transparent text-gray-500 hover:border-gray-300 hover:text-gray-700 inline-flex items-center px-1 pt-1 border-b-2 text-sm font-medium"
              >
                Settlements
              </router-link>
              <router-link
                to="/compliance"
                class="border-transparent text-gray-500 hover:border-gray-300 hover:text-gray-700 inline-flex items-center px-1 pt-1 border-b-2 text-sm font-medium"
              >
                Compliance
              </router-link>
            </div>
          </div>
          <div class="flex items-center">
            <WalletButton />
            <ChainStatusIndicator class="ml-4" />
          </div>
        </div>
      </div>
    </nav>

    <!-- Main Content -->
    <main class="max-w-7xl mx-auto py-6 sm:px-6 lg:px-8">
      <router-view />
    </main>

    <!-- Global Notifications -->
    <div aria-live="assertive" class="fixed inset-0 flex items-end px-4 py-6 pointer-events-none sm:p-6 sm:items-start">
      <div class="w-full flex flex-col items-center space-y-4 sm:items-end">
        <transition-group
          enter-active-class="transform ease-out duration-300 transition"
          enter-from-class="translate-y-2 opacity-0 sm:translate-y-0 sm:translate-x-2"
          enter-to-class="translate-y-0 opacity-100 sm:translate-x-0"
          leave-active-class="transition ease-in duration-100"
          leave-from-class="opacity-100"
          leave-to-class="opacity-0"
        >
          <div
            v-for="notification in notifications"
            :key="notification.id"
            class="max-w-sm w-full bg-white shadow-lg rounded-lg pointer-events-auto ring-1 ring-black ring-opacity-5 overflow-hidden"
          >
            <div class="p-4">
              <div class="flex items-start">
                <div class="flex-shrink-0">
                  <component :is="notification.icon" class="h-6 w-6" :class="notification.iconClass" />
                </div>
                <div class="ml-3 w-0 flex-1 pt-0.5">
                  <p class="text-sm font-medium text-gray-900">{{ notification.title }}</p>
                  <p class="mt-1 text-sm text-gray-500">{{ notification.message }}</p>
                </div>
              </div>
            </div>
          </div>
        </transition-group>
      </div>
    </div>
  </div>
</template>

<script setup lang="ts">
import { onMounted, onUnmounted } from 'vue'
import { useSettlementStore } from '@/stores/settlement'
import { useWalletStore } from '@/stores/wallet'
import { useNotificationStore } from '@/stores/notification'
import { storeToRefs } from 'pinia'
import WalletButton from '@/components/WalletButton.vue'
import ChainStatusIndicator from '@/components/ChainStatusIndicator.vue'

const settlementStore = useSettlementStore()
const walletStore = useWalletStore()
const notificationStore = useNotificationStore()
const { notifications } = storeToRefs(notificationStore)

onMounted(async () => {
  // Initialize WebSocket connections
  await settlementStore.connectWebSocket()

  // Auto-connect wallet if previously connected
  const previouslyConnected = localStorage.getItem('wallet_connected')
  if (previouslyConnected === 'true') {
    await walletStore.connect()
  }
})

onUnmounted(() => {
  settlementStore.disconnectWebSocket()
})
</script>

<style>
#app {
  font-family: 'Inter', -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Oxygen, Ubuntu, Cantarell, 'Helvetica Neue', sans-serif;
  -webkit-font-smoothing: antialiased;
  -moz-osx-font-smoothing: grayscale;
}
</style>
