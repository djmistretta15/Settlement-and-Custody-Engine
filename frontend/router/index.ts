import { createRouter, createWebHistory } from 'vue-router'
import type { RouteRecordRaw } from 'vue-router'

const routes: RouteRecordRaw[] = [
  {
    path: '/',
    name: 'Dashboard',
    component: () => import('@/views/Dashboard.vue'),
    meta: { title: 'Dashboard' }
  },
  {
    path: '/vaults',
    name: 'Vaults',
    component: () => import('@/views/DashboardVaults.vue'),
    meta: { title: 'Vaults', requiresAuth: true }
  },
  {
    path: '/vaults/:id',
    name: 'VaultDetail',
    component: () => import('@/views/VaultDetail.vue'),
    meta: { title: 'Vault Details', requiresAuth: true }
  },
  {
    path: '/settlements',
    name: 'Settlements',
    component: () => import('@/views/SettlementSubmit.vue'),
    meta: { title: 'Settlements', requiresAuth: true }
  },
  {
    path: '/settlements/:id',
    name: 'SettlementDetail',
    component: () => import('@/views/SettlementDetail.vue'),
    meta: { title: 'Settlement Details', requiresAuth: true }
  },
  {
    path: '/compliance',
    name: 'Compliance',
    component: () => import('@/views/Compliance.vue'),
    meta: { title: 'Compliance', requiresAuth: true }
  },
  {
    path: '/chains',
    name: 'ChainStatus',
    component: () => import('@/views/ChainStatusPanel.vue'),
    meta: { title: 'Chain Status' }
  }
]

const router = createRouter({
  history: createWebHistory(import.meta.env.BASE_URL),
  routes
})

// Navigation guard
router.beforeEach((to, from, next) => {
  document.title = `${to.meta.title as string} | Settlement Engine`

  // Check wallet connection for protected routes
  if (to.meta.requiresAuth) {
    const walletConnected = localStorage.getItem('wallet_connected') === 'true'
    if (!walletConnected) {
      next({ name: 'Dashboard' })
      return
    }
  }

  next()
})

export default router
