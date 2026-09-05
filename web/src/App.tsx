import { Navigate, Route, Routes } from 'react-router-dom'
import { Layout } from './components/Layout'
import { getToken } from './lib/api'
import { AgentsPage } from './pages/Agents'
import { AiPage } from './pages/Ai'
import { CloudPage } from './pages/Cloud'
import { ContainersPage } from './pages/Containers'
import { Dashboard } from './pages/Dashboard'
import { DiscoveryPage } from './pages/Discovery'
import { EventsPage } from './pages/Events'
import { HostDetail } from './pages/HostDetail'
import { HomeAutomationPage } from './pages/HomeAutomation'
import { HostsPage } from './pages/Hosts'
import { InventoryPage } from './pages/Inventory'
import { IpmiPage } from './pages/Ipmi'
import { LoginPage } from './pages/Login'
import { MonitoringPage } from './pages/Monitoring'
import { NetworkPage } from './pages/Network'
import { ProtectionPage } from './pages/Protection'
import { RemediationPage } from './pages/Remediation'
import { ProxmoxPage } from './pages/Proxmox'
import { SchedulerPage } from './pages/Scheduler'
import { SecurityPage } from './pages/Security'
import { ServicesPage } from './pages/Services'
import { SettingsPage } from './pages/Settings'
import { SynologyPage } from './pages/Synology'
import { TerminalPage } from './pages/Terminal'
import { UpdatesPage } from './pages/Updates'

function Protected({ children }: { children: React.ReactNode }) {
  if (!getToken()) return <Navigate to={`/login?next=${encodeURIComponent(location.pathname)}`} replace />
  return <>{children}</>
}

export function App() {
  return (
    <Routes>
      <Route path="/login" element={<LoginPage />} />
      <Route
        element={
          <Protected>
            <Layout />
          </Protected>
        }
      >
        <Route path="/" element={<Dashboard />} />
        <Route path="/hosts" element={<HostsPage />} />
        <Route path="/hosts/:id" element={<HostDetail />} />
        <Route path="/inventory" element={<InventoryPage />} />
        <Route path="/monitoring" element={<MonitoringPage />} />
        <Route path="/network" element={<NetworkPage />} />
        <Route path="/cloud" element={<CloudPage />} />
        <Route path="/security" element={<SecurityPage />} />
        <Route path="/protection" element={<ProtectionPage />} />
        <Route path="/home" element={<HomeAutomationPage />} />
        <Route path="/containers" element={<ContainersPage />} />
        <Route path="/updates" element={<UpdatesPage />} />
        <Route path="/services" element={<ServicesPage />} />
        <Route path="/ai" element={<AiPage />} />
        <Route path="/agents" element={<AgentsPage />} />
        <Route path="/remediation" element={<RemediationPage />} />
        <Route path="/proxmox" element={<ProxmoxPage />} />
        <Route path="/synology" element={<SynologyPage />} />
        <Route path="/ipmi" element={<IpmiPage />} />
        <Route path="/terminal" element={<TerminalPage />} />
        <Route path="/discovery" element={<DiscoveryPage />} />
        <Route path="/scheduler" element={<SchedulerPage />} />
        <Route path="/events" element={<EventsPage />} />
        <Route path="/settings" element={<SettingsPage />} />
      </Route>
      <Route path="*" element={<Navigate to="/" replace />} />
    </Routes>
  )
}
