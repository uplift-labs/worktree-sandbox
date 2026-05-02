/** @jsxImportSource @opentui/solid */
import { createSignal, onCleanup } from "solid-js"
import { createBranchObserver, resolveSandboxWorktree } from "./worktree-sandbox-branch-core.js"

function eventSessionID(event) {
  return event?.properties?.sessionID || event?.properties?.info?.id || event?.sessionID || ""
}

function BranchBadge(props) {
  const [branch, setBranch] = createSignal("")
  const api = props.api
  const observer = createBranchObserver({
    sessionID: props.sessionID,
    getWorktree() {
      return resolveSandboxWorktree({
        sessionID: props.sessionID,
        directory: api.state.path.directory,
        worktreeHint: api.state.path.worktree,
      })
    },
    onChange(next) {
      setBranch(next.branch)
    },
    onError(error, phase) {
      if (process.env.AISB_OPENCODE_BRANCH_DEBUG !== "1") return
      api.ui.toast({
        variant: "warning",
        message: `branch ${phase} failed: ${error?.message || error}`,
        duration: 3000,
      })
    },
  })

  const off = ["session.status", "session.updated", "session.idle", "tool.execute.after", "file.watcher.updated"].map(
    (type) =>
      api.event.on(type, (event) => {
        const id = eventSessionID(event)
        if (props.sessionID && id && id !== props.sessionID) return
        void observer.refresh(`event:${type}`)
      }),
  )

  onCleanup(() => {
    for (const stop of off) stop()
    observer.close()
  })

  const text = () => {
    if (!branch()) return ""
    const label = process.env.AISB_OPENCODE_BRANCH_LABEL || "branch"
    return `${label}:${branch()}`
  }

  return (
    <text fg={api.theme.current.textMuted}>
      {text()}
    </text>
  )
}

const tui = async (api) => {
  api.slots.register({
    order: 50,
    slots: {
      home_prompt_right() {
        return <BranchBadge api={api} />
      },
      session_prompt_right(props) {
        return <BranchBadge api={api} sessionID={props.session_id} />
      },
    },
  })
}

export default {
  id: "worktree-sandbox.branch",
  tui,
}
