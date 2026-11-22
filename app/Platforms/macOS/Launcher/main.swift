import CevicheMac

// The app itself lives in CevicheKit.framework, which the index service and the MCP helper share.
MainActor.assumeIsolated { CevicheMain.run() }
