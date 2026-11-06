import { useRef, useState } from 'react';
import { Link } from 'react-router';
import { useTranslation } from 'react-i18next';
import { useMutation, useQueryClient } from '@tanstack/react-query';
import { useRequiredSession } from '../../app/auth/sessionContext';
import { supabase } from '../../lib/supabase';
import { useLiveRefetch } from '../../lib/useLiveRefetch';
import { useNow } from '../../lib/useNow';
import { IconReady, IconWarning } from '../washroom/Icons';
import { errorMessageKey, RpcError, unwrap } from '../washroom/rpcError';
import { useMyRoles } from '../washroom/useMyRoles';
import { useAreas } from '../washroom/washroomData';
import { cleanTaskText, isNobodyOnDuty, minutesBetween, TASK_MAX } from './tasksLogic';
import { useManagers, useTasks, type Task } from './tasksData';
import '../../lib/forms.css';
import './tasks.css';

// Tasks (owner 2026-11-06): the owner sends a short job to a named manager or to the manager on duty;
// the assignee is pushed at once and every 10 minutes until they mark it done (optional note), then the
// owners are told. Work direction only: no per-person statistics, counts or rankings anywhere.

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
  const clock = useClock();
  const tasks = useTasks(plantId, true);
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
  const done = (tasks.data ?? []).filter((x) => x.done_at);

  return (
    <>
      <section className="card" aria-labelledby="new-task">
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
          <div role="status" aria-live="polite">
            {message && <p className={message.ok ? 'notice' : 'error'}>{message.text}</p>}
          </div>
          <button type="submit" className="task-big" disabled={send.isPending}>
            {send.isPending ? t('tasks.sending') : t('tasks.send')}
          </button>
        </form>
      </section>

      <h2>{t('tasks.openTitle')}</h2>
      {tasks.isPending && <p role="status">{t('common.loading')}</p>}
      {tasks.isSuccess && open.length === 0 && <p>{t('tasks.noneOpen')}</p>}
      <ul className="task-list">
        {open.map((x) => (
          <li key={x.task_id ?? ''} className="task-card open">
            <p className="task-body">{x.body}</p>
            <p className="hint">
              {x.to_on_duty
                ? t('tasks.toOnDuty', { names: nameOf(x.assignee_user_ids) })
                : t('tasks.toNamed', { names: nameOf(x.assignee_user_ids) })}
            </p>
            <p>
              <IconWarning />{' '}
              {t('tasks.openFor', { time: ago(minutesBetween(x.created_at ?? '', now)) })}
            </p>
          </li>
        ))}
      </ul>

      <h2>{t('tasks.doneTitle')}</h2>
      {tasks.isSuccess && done.length === 0 && <p className="hint">{t('tasks.noneDone')}</p>}
      <ul className="task-list">
        {done.map((x) => (
          <li key={x.task_id ?? ''} className="task-card done">
            <p className="task-body">{x.body}</p>
            <p>
              <IconReady /> {t('tasks.doneAt', { time: clock(x.done_at) })}
            </p>
            {x.done_note && <p className="hint">{t('tasks.note', { note: x.done_note })}</p>}
          </li>
        ))}
      </ul>
    </>
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
      <p className="task-body">{task.body}</p>
      <p className="hint">{t('tasks.sentAt', { time: clock(task.created_at) })}</p>
      <div className="field">
        <label htmlFor={`note-${id}`}>{t('tasks.noteLabel')}</label>
        <textarea
          id={`note-${id}`}
          maxLength={TASK_MAX}
          value={note}
          onChange={(e) => setNote(e.target.value)}
        />
      </div>
      {error && (
        <p className="error" role="alert">
          {error}
        </p>
      )}
      <button
        type="button"
        className="task-big"
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
  const clock = useClock();
  const tasks = useTasks(plantId, true);
  useLiveRefetch(tasks.refetch, true);
  const open = (tasks.data ?? []).filter((x) => !x.done_at);
  const done = (tasks.data ?? []).filter((x) => x.done_at);
  return (
    <>
      {open.length > 0 && (
        <p className="task-banner" role="status">
          <IconWarning /> {t('tasks.reminderBanner')}
        </p>
      )}
      {tasks.isPending && <p role="status">{t('common.loading')}</p>}
      {tasks.isError && <p className="error">{t(errorMessageKey(tasks.error))}</p>}
      {tasks.isSuccess && open.length === 0 && (
        <p className="notice">
          <IconReady /> {t('tasks.allDone')}
        </p>
      )}
      <ul className="task-list">
        {open.map((x) => (
          <MyTaskCard key={x.task_id ?? ''} task={x} />
        ))}
      </ul>
      {done.length > 0 && (
        <>
          <h2>{t('tasks.doneTitle')}</h2>
          <ul className="task-list">
            {done.map((x) => (
              <li key={x.task_id ?? ''} className="task-card done">
                <p className="task-body">{x.body}</p>
                <p>
                  <IconReady /> {t('tasks.doneAt', { time: clock(x.done_at) })}
                </p>
              </li>
            ))}
          </ul>
        </>
      )}
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
    <main className="form-page">
      <p>
        <Link to="/control">{t('common.back')}</Link>
      </p>
      <h1>{isOwner ? t('tasks.title') : t('tasks.myTitle')}</h1>
      {plantId && isOwner && <OwnerTasks plantId={plantId} />}
      {plantId && !isOwner && isManager && <MyTasks plantId={plantId} />}
      {plantId && !isOwner && !isManager && roles.size > 0 && (
        <p className="notice">{t('tasks.notForYou')}</p>
      )}
    </main>
  );
}
