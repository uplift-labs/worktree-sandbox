/** @jsxImportSource @opentui/solid */
import { For, Show, createSignal, onCleanup } from "solid-js"
import {
  acquireBuiltinFilesHidden,
  createBranchObserver,
  createChangedFilesObserver,
  resolveSandboxWorktree,
} from "./worktree-sandbox-branch-core.js"

const BRANCH_REFRESH_EVENTS = ["session.idle", "tool.execute.after", "file.watcher.updated"]
const FILE_REFRESH_EVENTS = ["session.idle", "tool.execute.after", "file.watcher.updated", "session.diff"]

function branchBadgeEnabled() {
  return process.env.AISB_OPENCODE_BRANCH_BADGE === "1"
}

function hideBuiltinFilesEnabled() {
  return process.env.AISB_OPENCODE_HIDE_BUILTIN_FILES === "1"
}

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

  const off = BRANCH_REFRESH_EVENTS.map(
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

function SandboxFiles(props) {
  const [files, setFiles] = createSignal([])
  const [open, setOpen] = createSignal(true)
  const api = props.api
  let releaseBuiltinFiles = undefined
  const updateBuiltinFilesVisibility = (worktree) => {
    if (!hideBuiltinFilesEnabled()) return

    if (worktree && !releaseBuiltinFiles) {
      releaseBuiltinFiles = acquireBuiltinFilesHidden(api, {
        onError(error, phase) {
          if (process.env.AISB_OPENCODE_FILES_DEBUG !== "1") return
          api.ui.toast({
            variant: "warning",
            message: `sandbox files ${phase} failed: ${error?.message || error}`,
            duration: 3000,
          })
        },
      })
      return
    }

    if (!worktree && releaseBuiltinFiles) {
      releaseBuiltinFiles()
      releaseBuiltinFiles = undefined
    }
  }
  const observer = createChangedFilesObserver({
    sessionID: props.sessionID,
    getWorktree() {
      return resolveSandboxWorktree({
        sessionID: props.sessionID,
        directory: api.state.path.directory,
        worktreeHint: api.state.path.worktree,
      })
    },
    onChange(next) {
      setFiles(next.files)
      updateBuiltinFilesVisibility(next.worktree)
    },
    onError(error, phase) {
      if (process.env.AISB_OPENCODE_FILES_DEBUG !== "1") return
      api.ui.toast({
        variant: "warning",
        message: `sandbox files ${phase} failed: ${error?.message || error}`,
        duration: 3000,
      })
    },
  })

  const off = FILE_REFRESH_EVENTS.map((type) =>
    api.event.on(type, (event) => {
      const id = eventSessionID(event)
      if (props.sessionID && id && id !== props.sessionID) return
      observer.schedule(`event:${type}`)
    }),
  )

  onCleanup(() => {
    if (releaseBuiltinFiles) releaseBuiltinFiles()
    for (const stop of off) stop()
    observer.close()
  })

  const title = () => process.env.AISB_OPENCODE_FILES_LABEL || "Sandbox Modified Files"

  return (
    <Show when={files().length > 0}>
      <box>
        <box flexDirection="row" gap={1} onMouseDown={() => files().length > 2 && setOpen((value) => !value)}>
          <Show when={files().length > 2}>
            <text fg={api.theme.current.text}>{open() ? "▼" : "▶"}</text>
          </Show>
          <text fg={api.theme.current.text}>
            <b>{title()}</b>
          </text>
        </box>
        <Show when={files().length <= 2 || open()}>
          <For each={files()}>
            {(item) => (
              <box flexDirection="row" gap={1} justifyContent="space-between">
                <text fg={api.theme.current.textMuted} wrapMode="none">
                  {item.file}
                </text>
                <box flexDirection="row" gap={1} flexShrink={0}>
                  <Show when={item.additions}>
                    <text fg={api.theme.current.diffAdded}>+{item.additions}</text>
                  </Show>
                  <Show when={item.deletions}>
                    <text fg={api.theme.current.diffRemoved}>-{item.deletions}</text>
                  </Show>
                </box>
              </box>
            )}
          </For>
        </Show>
      </box>
    </Show>
  )
}

const tui = async (api) => {
  if (branchBadgeEnabled()) {
    api.slots.register({
      order: 50,
      slots: {
        home_prompt_right() {
          return <BranchBadge api={api} />
        },
        session_prompt_right(_ctx, props) {
          return <BranchBadge api={api} sessionID={props.session_id} />
        },
      },
    })
  }

  api.slots.register({
    order: 490,
    slots: {
      sidebar_content(_ctx, props) {
        return <SandboxFiles api={api} sessionID={props.session_id} />
      },
    },
  })
}

export default {
  id: "worktree-sandbox.branch",
  tui,
}
