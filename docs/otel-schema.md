# Magisk Cross-Repo OTEL Schema

Backend: GitLab Observability (group-level)  
Group: `magisk3171` (`136325658`)  
OTLP HTTP: `https://136325658.otel.gitlab-o11y.com:14318/v1/traces`

## Resource attributes (required)

| Attribute | Example | Notes |
| --- | --- | --- |
| `service.name` | `magisk-ci`, `xposedsmscode`, `xinyi-relay`, `mipushframework` | Stable service id |
| `service.version` | commit SHA or `versionName` | Prefer immutable |
| `deployment.environment.name` | `ci`, `debug`, `release` | |
| `gitlab.project.id` | `83955172` | Links to GitLab project |
| `gitlab.project.name` | `XposedSmsCode` | Display |

### Project map

| service.name | project | gitlab.project.id |
| --- | --- | --- |
| `xposedsmscode` | XposedSmsCode | `83955172` |
| `xinyi-relay` | xinyi-relay | `84113188` |
| `mipushframework` | MiPushFramework | `83955143` |
| `magisk-ci` | any (CI jobs) | job's `CI_PROJECT_ID` |

## Span names

### CI (`service.name=magisk-ci`)

| Span | When |
| --- | --- |
| `ci.job` | default job end (android base `after_script`) |
| `ci.build` | optional explicit build finish |
| `ci.detekt` | optional explicit detekt finish |
| `ci.telegram` | telegram notify finish |
| `ci.release` | release publish finish |

CI attributes: `ci.pipeline_id`, `ci.job.id`, `ci.job.name`, `ci.job.stage`, `ci.job.status`, `ci.ref`, `ci.tag`, `ci.runner`.

### App runtime (opt-in only)

| Span | Meaning |
| --- | --- |
| `app.boot` | Application main process started |
| `app.secret_code` | Secret code receiver open-main path |
| `app.recovery` | Force-stop recovery wakeup |
| `app.kill` | Kill-self control path |
| `app.monitor` | App service monitor initializer |
| `app.lifecycle` | App foreground/background transitions |
| `app.alert` | Local special-alert notifications |
| `sms.pipeline` | End-to-end SMS post-parse pipeline |
| `sms.dispatch` | Hook SMS dispatch gate |
| `sms.process` | Hook SMS parse/blacklist decision inside dispatch |
| `sms.observe` | Inbox observer fallback path |
| `sms.operate` | SMS delete / mark-as-read operate path |
| `sms.parse` | SMS/code parse attempt |
| `sms.relay` | Relay IPC broadcast dispatch |
| `sms.ingest` | Relay host ingest / ForwardReceiver outcome |
| `sms.custom` | Custom message ingest |
| `sms.event` | Relay EventPipeline process outcome |
| `sms.schedule` | Scheduled task / auto-input claim scheduling |
| `sms.forward` | Relay/forward sender attempt |
| `sms.block` | SMS forward blacklist/pref block path |
| `sms.sender_runtime` | Sender runtime installer |
| `sms.record` | SMS history record attempt |
| `sms.copy` | Copy code to clipboard |
| `sms.toast` | Code toast display |
| `auto.input` | Auto-input code attempt |
| `a11y.service` | Auto-input accessibility service lifecycle |
| `call.alert` | Call alert monitor refresh |
| `battery.reminder` | Battery/charging reminder dispatch |
| `notify.owned` | App-owned notification path |
| `notify.cancel` | Code notification auto-cancel |
| `notify.intercept` | System NMS notification intercept/forward |
| `notify.identity` | Target-package notification identity notify/cancel |
| `hook.load` | Xposed hook package load / core install |
| `hook.init` | SMS hook constructor/runtime init |
| `hook.service` | Xposed service bind / died / register |
| `hook.conflict` | Module conflict arbiter decision |
| `hook.cache` | Hook prefs/rules cache invalidation |
| `hook.bridge` | Hook runtime bridge install |
| `prefs.restore` | Settings/rule/database restore |
| `prefs.access` | Hook prefs access install |
| `prefs.commit` | Atomic preference commit batch |
| `prefs.backup` | Settings/rule backup export |
| `push.boot` | Boot / package-replaced push startup |
| `push.register` | Push re-register schedule |
| `push.service` | Push service enable/disable |
| `push.manager` | Manager write runtime executor ops |
| `push.servicebox` | Service box / subproc bridge lifecycle |
| `push.lifecycle` | XMPushService lifecycle bridge |
| `push.facade` | MiPush facade service lifecycle |
| `push.network` | Network status change handling |
| `push.receive` | MiPush payload received before publish |
| `push.dispatch` | MiPush notification dispatch |
| `push.island` | HyperIsland / focus island post |
| `push.xspace` | XSpace package sync hook |
| `push.package` | Package added/removed handling |
| `push.account` | Account change handling |
| `push.control` | Internal push control message |
| `push.keepalive` | Keep-alive service poke |
| `push.event` | Notification event observer |

App attributes (allow-list; never put code body / phone / token):

- `result` = `ok|error|skip`
- `duration_ms`
- `delay_ms` (sms.schedule auto-input claim delay)
- `found_count` (app.recovery process restart found targets)
- `killed_count` (app.recovery process restart killed targets)
- `process`
- `abi`
- `error_class`
- `reason` (skip/error reason token)
- `code_length` (sms.parse / auto.input / sms.copy / sms.toast; never the code itself)
- `body_length` (sms.observe only; body size, never content)
- `company_present` (`true|false`, sms.parse)
- `sender_type` (sms.forward channel type key only)
- `msg_type` / `source` (sms.relay / notify.intercept / auto.input injector)
- `reason_token` (push.network channel_open sanitized reason token)
- `target_package` (push.receive / push.dispatch target app package)
- `payload_size` (push.receive payload bytes)
- `pending_count` (queued pending push messages/registrations)
- `network_available` (`true|false`, push.network)
- `retry_index` (push.register)
- `action` (push.boot / push.network intent action)
- `action_block` (`true|false`, sms.block match)
- `action_delete` (`true|false`, sms.block match)
- `stage` (prefs.restore / notify.owned / sms.observe / push.island / root_shell / config_snapshot / nms_forward / force / force_helper / force_helper_fallback / proactive / helper / a11y_publish / mock_replay / module_runtime / external_ingress / blacklist_hit_ipc / parsed_code_forward / schedule_all / handled_mark / pdu_count / dedupe_* / pre_route / sender_scope / sms_ingress / event_retention / permission_grant / runtime_gate / framework_compat / mms / mms_hook / sms_provider / service_bind / service_died / log_bundle_export / log_bundle_clear / forward_hook / hook_install / kill_guard / activate_scan / activate_account / activate_awake / message_handler / runtime_dispatch / runtime_connection / runtime_boot / runtime_force / sms_handler / vendor_hook / click_route / amap_liveview / client_call / client_handshake / client_bind / notify_publish / handshake / diagnostics_install / module_status / packet_prepare / state_store / connection_status / payload_dispatch_plan / config_sync / timeout_runner / dispatch_decision / update_verify / update_check / launch_package / open_view_uri / runtime_log_clear / runtime_log_export / remote_agent / socket_tcp / socket_udp / socket_mqtt / webdav_upload / webdav_restore / webdav_test / gdrive_upload / fake_device / webhook_http / mms_pdu_parse / duplicate_check / result_persist / forward_result sub-stage / matrix_e2ee / matrix_verify / agent_bind / agent_clear / agent_heartbeat / agent_pull / agent_push / agent_upload / island_dispatch / system_service / packet_sync / security_core / inspect_backup / registration_result / unregistration_result / command_result / message_processor / notification_process / app_delivery / style_path / runtime_framework_register / runtime_app_register / runtime_pending_register / runtime_downstream / runtime_cancel / runtime_ensure_connection / runtime_reset_connection / runtime_sync_account_alias / sms_send_backend / nms_permission / sender_validate / component_visibility / email_send / telegram_send / bark_send / feishu_send / dingtalk_send / wework_send / matrix_plaintext / registration_repair / sms_inbox_observer / forward_policy / manager_force_register / manager_mock_replay / manager_event_delete / manager_log_export / manager_log_clear / push_message_handler / packet_register / packet_send / xposed_service_bind / xposed_service_died / xposed_service_bridge / urlscheme_send / wework_robot_send / dingtalk_group_send / ntfy_send / yunhu_send / gotify_send / sms_utils_send / pushplus_send / feishu_webhook_send / serverchan_send / pushdeer_send / code_record_restore / bg_activity_start_enabler / call_session / focus_registry / voip_stale_drop / standard_sms / standard_mms / standard_mode_gate / identity_notify / identity_cancel / sdk_register / sdk_unregister / ack_send / code_record / event_process / client_close / client_process_register_task / client_register / client_unregister / app_db_register / app_db_unregister / sender_test / sender_test_sms / channel_closed / channel_open / channel_kick / client_event_service_started / focus_auth_hook / focus_auth_bypass / shortcut_permission / tinydata_upload)
- `strategy` (auto.input accessibility strategy token)
- `event_id_present` (`true` when pipeline has event id; never the raw id)
- `code_present` (`true|false` when a code was detected without recording it)
- `application_id_present` (`true|false`, hook.load)
- `auto_input_enabled` (`true|false`, sms.pipeline plan)
- `should_record` (`true|false`, sms.pipeline plan)
- `magisk.event` (same as span name)
- `operation` (push.manager write op token only; never args/values)
- `change_count` (prefs.commit batch size; never key names/values)
- `include_database` (`true|false`, prefs.backup)
- `rule_count` (prefs.backup rule list size)
- `package_action` (push.xspace package added/removed/replaced token)

## Enablement

### CI

- Default: export on (`MAGISK_OTEL_EXPORT=1`) via `ci/otel_export.sh`
- Disable: set group/project CI variable `MAGISK_OTEL_EXPORT=0`
- Endpoint override: `MAGISK_OTEL_ENDPOINT`
- Service override: `MAGISK_OTEL_SERVICE_NAME` (default `magisk-ci`)

### App

- Default: **disabled**
- Enable: `MagiskOtel.configure(enabled=true)` or system property `magisk.otel.enabled=true`
- DEBUG builds may auto-enable a boot probe only

## Privacy

- No SMS body, verification codes, tokens, cookies, Authorization headers
- Prefer counts/results/durations
- Release builds must keep export off unless user explicitly opts in later
- `target_count` (sms.forward SMS send recipient count)
- `content_length` (sms.forward message length only)
- `wait_for_result` (`true|false`, sms.forward)
- `sim_slot` (sms.forward selected SIM slot index)
- `region_present` (`true|false`, push.register)
- `error_code` (push.register / push.control numeric status only)
- `scanned_count` (sms.observe inbox scan/repair count)
- `updated_count` (sms.observe routing repair updates)
- `handled_count` (sms.observe handled inbox records)
- `imported_count` (sms.record restore import size)
- `call_stage` (call.alert normalized call stage token)
- `package_present` (`true|false`, call.alert)
- `number_present` (`true|false`, call.alert; never raw number)
- `write_mode` (push.island focus registry write path token)
- `key_count` (push.island focus registry key size)
