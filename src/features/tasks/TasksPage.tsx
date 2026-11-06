import { useRef, useState } from 'react';
import { useTranslation } from 'react-i18next';
import { useMutation, useQueryClient } from '@tanstack/react-query';
import { useRequiredSession } from '../../app/auth/sessionContext';
import { supabase } from '../../lib/supabase';
import { useLiveRefetch } from '../../lib/useLiveRefetch';
import { useNow } from '../../lib/useNow';
import { IconBell, IconReady, IconTasks, IconWarning } from '../washroom/Icons';
import { errorMessageKey, RpcError, unwrap } from '../washroom/rpcError';
import { useMyRoles } from '../washroom/useMyRoles';
import { useAreas } from '../washroom/washroomData';
import { cleanTaskText, isNobodyOnDuty, minutesBetween, TASK_MAX } from './tasksLogic';
import { useManagers, useTasks, type Task } from './tasksData';
import '../../lib/forms.css';
import './tasks.css';

// Tasks (owner 2026-11-06; redesign 2026-11-06): the owner sends a short job to a named manager or to
// the manager on duty; the assignee is pushed at once and every 10 minutes until they mark it done
// (optional note), then the owners are told. Open = amber card, done = blue. Open / Done filter.
// Work direction only: no per-person statistics, counts or rankings anywhere; no snooze, no
// signatures or photo proof (design README).
// Review (owner 2026-11-06): a done task waits on the owners' screen until one owner taps Reviewed;
// then it leaves every list (kept in the database, never deleted). Managers see only open tasks.
// Names (who sent it, who marked it done) come from the server for owners only.

function useAgo() {
  const { t } = useTranslation();
  return (minutes: number) =>
    minutes < 60
      ? t('tasks.minutes', { count: minutes })
      : t('tasks.hours', { h: Math.floor(minutes / 60), m: minutes % 60 });
}

function useClock() {
  const { i18n } = useTranslation();
  return (iso: string | null) =>
    iso
      ? new Intl.DateTimeFormat(i18n.language, {
          weekday: 'short',
          hour: 'numeric',
          minute: '2-digit',
        }).format(new Date(iso))
      : '';
}

function OwnerTasks({ plantId }: { plantId: string }) {
  const { t } = useTranslation();
  const qc = useQueryClient();
  const now = useNow(30_000);
  const ago = useAgo();
  const tasks = useTasks(plantId, false);
  useLiveRefetch(tasks.refetch, true);
  const managers = useManagers(plantId, true);
  const [body, setBody] = useState('');
  const [to, setTo] = useState(''); // '' = manager on duty
  const [message, setMessage] = useState<{ ok: boolean; text: string } | null>(null);
  const clientId = useRef<string | null>(null);
  const nameOf = (ids: readonly string[] | null) =>
    (ids ?? [])
      .map((id) => managers.data?.find((m) => m.user_id === id)?.name ?? t('tasks.aManager'))
      .join(', ');

  const send = useMutation({
    mutationFn: async (text: string) => {
      clientId.current ??= crypto.randomUUID();
      return unwrap(
        await supabase.rpc('create_task', {
          p_plant_id: plantId,
          p_body: text,
          p_client_id: clientId.current,
          ...(to ? { p_assignee_user_id: to } : {}),
        }),
      );
    },
    onSuccess: () => {
      clientId.current = null;
      setBody('');
      setMessage({ ok: true, text: t('tasks.sent') });
    },
    onError: (e) =>
      setMessage({
        ok: false,
        text:
          e instanceof RpcError && isNobodyOnDuty(e.detail)
            ? t('tasks.nobodyOnDuty')
            : t(errorMessageKey(e)),
      }),
    onSettled: () => void qc.invalidateQueries({ queryKey: ['tasks'] }),
  });

  const open = (tasks.data ?? []).filter((x) => !x.done_at);
  const done = (tasks.data ?? []).filter((x) => x.done_at && x.awaiting_review);
  const [composing, setComposing] = useState(false);
  const [filter, setFilter] = useState<'open' | 'done'>('open');
  const showForm = composing || (tasks.isSuccess && open.length === 0 && done.length === 0);

  return (
    <>
      {!showForm && (
        <button type="button" className="task-new" onClick={() => setComposing(true)}>
          <IconTasks size="1.4em" /> {t('tasks.newButton')}
        </button>
      )}
      {showForm && (
        <section className="task-compose" aria-labelledby="new-task">
          <h2 id="new-task">{t('tasks.newTitle')}</h2>
          <form
            noValidate
            onSubmit={(e) => {
              e.preventDefault();
              const text = cleanTaskText(body);
              if (!text)
                return setMessage({ ok: false, text: t('tasks.errors.text', { max: TASK_MAX }) });
              send.mutate(text);
            }}
          >
            <div className="field">
              <label htmlFor="task-body">{t('tasks.textLabel')}</label>
              <textarea
                id="task-body"
                maxLength={TASK_MAX}
                value={body}
                onChange={(e) => {
                  setBody(e.target.value);
                  clientId.current = null;
                }}
                aria-describedby="task-body-count"
              />
              <p id="task-body-count" className="hint">
                {t('tasks.count', { n: body.length, max: TASK_MAX })}
              </p>
            </div>
            <div className="field">
              <label htmlFor="task-to">{t('tasks.sendTo')}</label>
              <select
                id="task-to"
                value={to}
                onChange={(e) => {
                  setTo(e.target.value);
                  clientId.current = null;
                }}
              >
                <option value="">{t('tasks.onDuty')}</option>
                {(managers.data ?? []).map((m) => (
                  <option key={m.user_id} value={m.user_id}>
                    {m.name}
                  </option>
                ))}
              </select>
              {managers.isError && <p className="hint">{t('tasks.namesUnavailable')}</p>}
            </div>
            <p className="task-reminder">
              <IconBell /> {t('tasks.reminderEvery')}
            </p>
            <div className="actions">
              <button type="submit" className="task-big" disabled={send.isPending}>
                {send.isPending ? t('tasks.sending') : t('tasks.send')}
              </button>
              {composing && (
                <button type="button" className="secondary" onClick={() => setComposing(false)}>
                  {t('common.cancel')}
                </button>
              )}
            </div>
          </form>
        </section>
      )}
      <div role="status" aria-live="polite">
        {message && <p className={message.ok ? 'notice' : 'error'}>{message.text}</p>}
      </div>

      <div className="task-filter" role="group" aria-label={t('tasks.filterLabel')}>
        <button type="button" aria-pressed={filter === 'open'} onClick={() => setFilter('open')}>
          {t('tasks.filterOpen', { count: open.length })}
        </button>
        <button type="button" aria-pressed={filter === 'done'} onClick={() => setFilter('done')}>
          {t('tasks.filterReview', { count: done.length })}
        </button>
      </div>
      {tasks.isPending && <p role="status">{t('common.loading')}</p>}
      {tasks.isError && <p className="error">{t(errorMessageKey(tasks.error))}</p>}

      {filter === 'open' && (
        <>
          {tasks.isSuccess && open.length === 0 && (
            <p className="task-empty">
              <IconReady /> {t('tasks.noneOpen')}
            </p>
          )}
          <ul className="task-list">
            {open.map((x) => (
              <li key={x.task_id ?? ''} className="task-card open">
                <div className="task-card-head">
                  <span className="status-pill warn">
                    <IconWarning /> {t('tasks.openPill')}
                  </span>
                  <span className="mono task-age">
                    {minutesBetween(x.created_at ?? '', now) < 1
                      ? t('tasks.justSent')
                      : t('tasks.openFor', { time: ago(minutesBetween(x.created_at ?? '', now)) })}
                  </span>
                </div>
                <p className="task-body">{x.body}</p>
                <p className="task-meta">
                  {x.to_on_duty
                    ? t('tasks.toOnDuty', { names: nameOf(x.assignee_user_ids) })
                    : t('tasks.toNamed', { names: nameOf(x.assignee_user_ids) })}
                </p>
                <p className="task-meta">
                  <IconBell /> {t('tasks.reminderEvery')}
                </p>
                {x.created_by_name && (
                  <p className="task-meta">{t('tasks.sentBy', { name: x.created_by_name })}</p>
                )}
              </li>
            ))}
          </ul>
        </>
      )}
      {filter === 'done' && (
        <>
          {tasks.isSuccess && done.length === 0 && (
            <p className="task-empty">
              <IconReady /> {t('tasks.noneToReview')}
            </p>
          )}
          <ul className="task-list">
            {done.map((x) => (
              <ReviewCard key={x.task_id ?? ''} task={x} />
            ))}
          </ul>
        </>
      )}
    </>
  );
}

/** Owner: a done task waiting for review. One owner's Reviewed clears it for both owners. */
function ReviewCard({ task }: { task: Task }) {
  const { t } = useTranslation();
  const qc = useQueryClient();
  const clock = useClock();
  const [error, setError] = useState<string | null>(null);
  const review = useMutation({
    mutationFn: async () =>
      unwrap(await supabase.rpc('review_task', { p_task_id: task.task_id ?? '' })),
    onSuccess: () => setError(null),
    onError: (e) => setError(t(errorMessageKey(e))),
    onSettled: () => void qc.invalidateQueries({ queryKey: ['tasks'] }),
  });
  return (
    <li className="task-card done">
      <div className="task-card-head">
        <span className="status-pill info">
          <IconReady /> {t('tasks.donePill')}
        </span>
        <span className="mono task-age">{clock(task.done_at)}</span>
      </div>
      <p className="task-body">{task.body}</p>
      {task.done_by_name && (
        <p className="task-meta">{t('tasks.doneBy', { name: task.done_by_name })}</p>
      )}
      {task.done_note && <p className="task-meta">{t('tasks.note', { note: task.done_note })}</p>}
      {error && (
        <p className="error" role="alert">
          {error}
        </p>
      )}
      <button
        type="button"
        className="task-big task-done-button"
        disabled={review.isPending}
        onClick={() => review.mutate()}
      >
        <IconReady /> {t('tasks.reviewed')}
      </button>
    </li>
  );
}

function MyTaskCard({ task }: { task: Task }) {
  const { t } = useTranslation();
  const qc = useQueryClient();
  const clock = useClock();
  const [note, setNote] = useState('');
  const [error, setError] = useState<string | null>(null);
  const id = task.task_id ?? '';
  const done = useMutation({
    mutationFn: async () => {
      const clean = note.trim() ? cleanTaskText(note) : null;
      if (note.trim() && !clean)
        throw new RpcError('VALIDATION_FAILED', 'note', 'VALIDATION_FAILED');
      return unwrap(
        await supabase.rpc('complete_task', { p_task_id: id, ...(clean ? { p_note: clean } : {}) }),
      );
    },
    onSuccess: () => setError(null),
    onError: (e) => setError(t(errorMessageKey(e))),
    onSettled: () => void qc.invalidateQueries({ queryKey: ['tasks'] }),
  });
  return (
    <li className="task-card open mine">
      <div className="task-card-head">
        <span className="status-pill warn">
          <IconWarning /> {t('tasks.openPill')}
        </span>
        <span className="mono task-age">{t('tasks.sentAt', { time: clock(task.created_at) })}</span>
      </div>
      <p className="task-body">{task.body}</p>
      <details className="task-note">
        <summary>{t('tasks.addNote')}</summary>
        <div className="field">
          <label htmlFor={`note-${id}`}>{t('tasks.noteLabel')}</label>
          <textarea
            id={`note-${id}`}
            maxLength={TASK_MAX}
            value={note}
            onChange={(e) => setNote(e.target.value)}
          />
        </div>
      </details>
      {error && (
        <p className="error" role="alert">
          {error}
        </p>
      )}
      <button
        type="button"
        className="task-big task-done-button"
        disabled={done.isPending}
        onClick={() => done.mutate()}
      >
        {t('tasks.done')}
      </button>
    </li>
  );
}

function MyTasks({ plantId }: { plantId: string }) {
  const { t } = useTranslation();
  // Managers get only their open tasks: a task leaves this list as soon as it is marked done.
  const tasks = useTasks(plantId, false);
  useLiveRefetch(tasks.refetch, true);
  const open = (tasks.data ?? []).filter((x) => !x.done_at);
  return (
    <>
      {open.length > 0 && (
        <p className="task-banner" role="status">
          <IconWarning size="1.4em" /> {t('tasks.reminderBanner')}
        </p>
      )}
      {tasks.isPending && <p role="status">{t('common.loading')}</p>}
      {tasks.isError && <p className="error">{t(errorMessageKey(tasks.error))}</p>}
      {tasks.isSuccess && open.length === 0 && (
        <p className="task-empty">
          <IconReady /> {t('tasks.allDone')}
        </p>
      )}
      <ul className="task-list">
        {open.map((x) => (
          <MyTaskCard key={x.task_id ?? ''} task={x} />
        ))}
      </ul>
    </>
  );
}

export function TasksPage() {
  const { t } = useTranslation();
  const session = useRequiredSession();
  const areas = useAreas();
  const plantId = areas.data?.[0]?.plant_id;
  const roles = useMyRoles(session.user.id).rolesFor(plantId);
  const isOwner = roles.has('owner');
  const isManager = roles.has('manager');
  return (
    <main className="form-page task-page">
      <h1>{isOwner ? t('tasks.title') : t('tasks.myTitle')}</h1>
      {plantId && isOwner && <OwnerTasks plantId={plantId} />}
      {plantId && !isOwner && isManager && <MyTasks plantId={plantId} />}
      {plantId && !isOwner && !isManager && roles.size > 0 && (
        <p className="notice">{t('tasks.notForYou')}</p>
      )}
    </main>
  );
}
