import { useEffect, useRef, useState, type FormEvent } from 'react';
import { useTranslation } from 'react-i18next';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { useRequiredSession } from '../../app/auth/sessionContext';
import { isValidUsername } from '../../lib/loginId';
import { isPasswordProblem, passwordProblem, passwordProblemKey } from '../../lib/passwordRules';
import { useNow } from '../../lib/useNow';
import { NewPasswordField } from '../../app/auth/NewPasswordField';
import {
  ASSIGNABLE_ROLES,
  callManageUsers,
  ManageUsersError,
  type AssignableRole,
  type Person,
  type TempPasswordResult,
} from './manageUsers';
import { useOwnerPlants } from './useOwnerPlants';
import { AlertToggles } from './AlertToggles';
import { ManagerSettings } from './ManagerSettings';
import { useAssignments, useShiftOptions } from './useManagerSchedule';
import { useAlertMemberships } from './useAlertMemberships';
import type { AlertMembership } from './alertRecipients';
import '../../lib/forms.css';

// Owner "People" screen (PRD A4, owner decision 2026-11-03): owner-created username + password
// accounts. Temporary passwords are shown once and kept only in component state.
// 2026-11-07: the owner may type the starting password (6 numbers that are not a simple pattern, or
// ≥ 10 characters; never echoed back), and unlocks people locked out by 5 wrong passwords.

function errorKey(e: unknown): string {
  if (e instanceof ManageUsersError) {
    if (isPasswordProblem(e.reason)) return `password.problems.${passwordProblemKey(e.reason)}`;
    if (e.code === 'NOT_AUTHORIZED') return 'people.errors.notAuthorized';
    if (e.code === 'USERNAME_TAKEN') return 'people.errors.usernameTaken';
    if (e.code === 'VALIDATION_FAILED') return 'people.errors.invalid';
  }
  return 'people.errors.generic';
}

interface Secret {
  username: string;
  password: string;
}

/** A locked_until in the future, else null. */
function activeLock(lockedUntil: string | null, now: number): Date | null {
  if (!lockedUntil) return null;
  const d = new Date(lockedUntil);
  return Number.isNaN(d.getTime()) || d.getTime() <= now ? null : d;
}

/** Optional owner-typed starting password: empty = the app makes one. */
function StartPasswordField({
  id,
  value,
  onChange,
}: {
  id: string;
  value: string;
  onChange: (v: string) => void;
}) {
  const { t } = useTranslation();
  const [letters, setLetters] = useState(false);
  return (
    <>
      <NewPasswordField
        id={id}
        label={t('people.startPasswordLabel')}
        value={value}
        onChange={onChange}
        letters={letters}
        onLettersChange={setLetters}
        shown
        describedBy={`${id}-optional`}
      />
      <p id={`${id}-optional`} className="hint">
        {t('people.startPasswordHint')}
      </p>
    </>
  );
}

function SecretBox({ secret, onDone }: { secret: Secret; onDone: () => void }) {
  const { t } = useTranslation();
  const headingRef = useRef<HTMLHeadingElement>(null);
  const [copy, setCopy] = useState<'idle' | 'copied' | 'failed'>('idle');

  useEffect(() => headingRef.current?.focus(), []);

  async function onCopy() {
    try {
      await navigator.clipboard.writeText(secret.password);
      setCopy('copied');
    } catch {
      setCopy('failed');
    }
  }

  return (
    <section className="secret" aria-labelledby="secret-title">
      <h2 id="secret-title" ref={headingRef} tabIndex={-1}>
        {t('people.secretTitle', { username: secret.username })}
      </h2>
      <p>
        <strong>{t('people.secretWarning')}</strong>
      </p>
      <output className="secret-value" aria-label={t('people.secretLabel')}>
        {secret.password}
      </output>
      <p className="hint">{t('people.secretNext')}</p>
      <div className="actions">
        <button type="button" onClick={onCopy}>
          {t('people.copy')}
        </button>
        <button type="button" className="secondary" onClick={onDone}>
          {t('people.done')}
        </button>
      </div>
      <p role="status" aria-live="polite">
        {copy === 'copied' && t('people.copied')}
        {copy === 'failed' && <span className="error">{t('people.copyFailed')}</span>}
      </p>
    </section>
  );
}

function PersonCard({
  person,
  selfId,
  plantId,
  plant,
  alertMemberships,
  shifts,
  assignments,
  onSecret,
  onStatus,
}: {
  person: Person;
  selfId: string;
  plantId: string;
  plant: { id: string; org_id: string };
  alertMemberships: AlertMembership[];
  shifts: Parameters<typeof ManagerSettings>[0]['shifts'];
  assignments: Parameters<typeof ManagerSettings>[0]['assignments'];
  onSecret: (s: Secret) => void;
  onStatus: (message: string) => void;
}) {
  const { t, i18n } = useTranslation();
  const queryClient = useQueryClient();
  const now = useNow(30_000);
  const [confirming, setConfirming] = useState(false);
  const [resetting, setResetting] = useState(false);
  const [resetPassword, setResetPassword] = useState('');
  const [resetError, setResetError] = useState<string | null>(null);
  const name = person.display_name ?? person.username ?? t('people.noUsername');
  const lock = activeLock(person.locked_until, now);

  const reset = useMutation({
    mutationFn: () =>
      callManageUsers<TempPasswordResult>({
        action: 'reset_password',
        plant_id: plantId,
        user_id: person.user_id,
        ...(resetPassword.length > 0 ? { password: resetPassword } : {}),
      }),
    onSuccess: (r) => {
      setResetting(false);
      setResetPassword('');
      setResetError(null);
      if (r.temp_password)
        onSecret({ username: person.username ?? name, password: r.temp_password });
      else onStatus(t('people.passwordSet', { name }));
    },
    onError: (e) => setResetError(t(errorKey(e))),
  });

  function onReset() {
    const problem = resetPassword.length > 0 ? passwordProblem(resetPassword) : null;
    if (problem) return setResetError(t(`password.problems.${passwordProblemKey(problem)}`));
    setResetError(null);
    reset.mutate();
  }

  const unlock = useMutation({
    mutationFn: () =>
      callManageUsers({ action: 'unlock', plant_id: plantId, user_id: person.user_id }),
    onSuccess: async () => {
      onStatus(t('people.unlocked', { name }));
      await queryClient.invalidateQueries({ queryKey: ['people', plantId] });
    },
    onError: (e) => onStatus(t(errorKey(e))),
  });

  const deactivate = useMutation({
    mutationFn: () =>
      callManageUsers({ action: 'deactivate', plant_id: plantId, user_id: person.user_id }),
    onSuccess: async () => {
      setConfirming(false);
      onStatus(t('people.deactivated', { name }));
      await queryClient.invalidateQueries({ queryKey: ['people', plantId] });
    },
    onError: (e) => onStatus(t(errorKey(e))),
  });

  const roles = person.memberships
    .map((m) =>
      [
        t(`roles.${m.role}`),
        m.can_manage_staff ? t('people.staffAdmin') : null,
        m.org_wide ? t('people.allPlants') : null,
      ]
        .filter(Boolean)
        .join(' · '),
    )
    .join('; ');

  return (
    <li className="card person-card">
      <h3 className="head">
        {name}
        {person.is_self && ` ${t('people.you')}`}
      </h3>
      <p>{t('people.usernameValue', { username: person.username ?? t('people.noUsername') })}</p>
      <p>{t('people.roleValue', { roles })}</p>
      {lock && (
        <div className="notice person-lock" role="group" aria-label={t('people.lockedLabel')}>
          <p>
            <span aria-hidden="true">🔒 </span>
            <strong>
              {t('people.lockedUntil', {
                time: new Intl.DateTimeFormat(i18n.language, {
                  hour: '2-digit',
                  minute: '2-digit',
                }).format(lock),
              })}
            </strong>
          </p>
          {person.manageable && (
            <button type="button" disabled={unlock.isPending} onClick={() => unlock.mutate()}>
              {t('people.unlock')}
            </button>
          )}
        </div>
      )}
      <AlertToggles
        userId={person.user_id}
        selfId={selfId}
        name={name}
        plant={plant}
        memberships={alertMemberships}
        onStatus={onStatus}
      />
      <ManagerSettings
        userId={person.user_id}
        name={name}
        plant={plant}
        memberships={alertMemberships}
        shifts={shifts}
        assignments={assignments}
        onStatus={onStatus}
      />
      {!person.is_self && !person.manageable && <p className="hint">{t('people.notManageable')}</p>}
      {person.manageable && resetting && (
        <div role="group" aria-label={t('people.resetPassword')}>
          <StartPasswordField
            id={`reset-${person.user_id}`}
            value={resetPassword}
            onChange={setResetPassword}
          />
          <div className="actions">
            <button type="button" disabled={reset.isPending} onClick={onReset}>
              {t('people.resetConfirm')}
            </button>
            <button
              type="button"
              className="secondary"
              onClick={() => {
                setResetting(false);
                setResetPassword('');
                setResetError(null);
              }}
            >
              {t('people.cancel')}
            </button>
          </div>
          <p role="status" aria-live="polite" className="error">
            {resetError}
          </p>
        </div>
      )}
      {person.manageable && !confirming && !resetting && (
        <div className="actions">
          <button type="button" className="secondary" onClick={() => setResetting(true)}>
            {t('people.resetPassword')}
          </button>
          <button type="button" className="secondary" onClick={() => setConfirming(true)}>
            {t('people.deactivate')}
          </button>
        </div>
      )}
      {person.manageable && confirming && (
        <div role="group" aria-label={t('people.confirmDeactivate', { name })}>
          <p>
            <strong>{t('people.confirmDeactivate', { name })}</strong>
          </p>
          <div className="actions">
            <button
              type="button"
              className="danger"
              disabled={deactivate.isPending}
              onClick={() => deactivate.mutate()}
            >
              {t('people.confirmYes')}
            </button>
            <button type="button" className="secondary" onClick={() => setConfirming(false)}>
              {t('people.cancel')}
            </button>
          </div>
        </div>
      )}
    </li>
  );
}

function CreateForm({
  plantId,
  onSecret,
  onStatus,
}: {
  plantId: string;
  onSecret: (s: Secret) => void;
  onStatus: (message: string) => void;
}) {
  const { t } = useTranslation();
  const queryClient = useQueryClient();
  const [displayName, setDisplayName] = useState('');
  const [username, setUsername] = useState('');
  const [role, setRole] = useState<AssignableRole>('manager');
  const [canManageStaff, setCanManageStaff] = useState(false);
  const [startPassword, setStartPassword] = useState('');
  const [error, setError] = useState<string | null>(null);

  const create = useMutation({
    mutationFn: () =>
      callManageUsers<TempPasswordResult>({
        action: 'create',
        plant_id: plantId,
        username,
        display_name: displayName.trim(),
        role,
        can_manage_staff: role === 'manager' && canManageStaff,
        ...(startPassword.length > 0 ? { password: startPassword } : {}),
      }),
    onSuccess: async (r) => {
      if (r.temp_password) onSecret({ username, password: r.temp_password });
      else onStatus(t('people.createdWithPassword', { username }));
      setDisplayName('');
      setUsername('');
      setRole('manager');
      setCanManageStaff(false);
      setStartPassword('');
      await queryClient.invalidateQueries({ queryKey: ['people', plantId] });
    },
    onError: (e) => setError(t(errorKey(e))),
  });

  function onSubmit(event: FormEvent) {
    event.preventDefault();
    if (displayName.trim().length === 0) return setError(t('people.errors.nameRequired'));
    if (!isValidUsername(username)) return setError(t('people.errors.usernameInvalid'));
    const problem = startPassword.length > 0 ? passwordProblem(startPassword) : null;
    if (problem) return setError(t(`password.problems.${passwordProblemKey(problem)}`));
    setError(null);
    create.mutate();
  }

  return (
    <form onSubmit={onSubmit} noValidate aria-labelledby="create-title">
      <h2 id="create-title">{t('people.createTitle')}</h2>
      <div className="field">
        <label htmlFor="new-display-name">{t('people.displayNameLabel')}</label>
        <input
          id="new-display-name"
          type="text"
          autoComplete="off"
          maxLength={80}
          required
          value={displayName}
          onChange={(e) => setDisplayName(e.target.value)}
        />
      </div>
      <div className="field">
        <label htmlFor="new-username">{t('people.usernameLabel')}</label>
        <input
          id="new-username"
          type="text"
          autoComplete="off"
          autoCapitalize="none"
          autoCorrect="off"
          spellCheck={false}
          maxLength={32}
          required
          aria-describedby="new-username-hint"
          value={username}
          onChange={(e) => setUsername(e.target.value.toLowerCase())}
        />
        <p id="new-username-hint" className="hint">
          {t('people.usernameHelp')}
        </p>
      </div>
      <div className="field">
        <label htmlFor="new-role">{t('people.roleLabel')}</label>
        <select
          id="new-role"
          value={role}
          onChange={(e) => setRole(e.target.value as AssignableRole)}
        >
          {ASSIGNABLE_ROLES.map((r) => (
            <option key={r} value={r}>
              {t(`roles.${r}`)}
            </option>
          ))}
        </select>
      </div>
      {role === 'manager' && (
        <div className="field check">
          <label>
            <input
              type="checkbox"
              checked={canManageStaff}
              onChange={(e) => setCanManageStaff(e.target.checked)}
            />
            {t('people.canManageStaffLabel')}
          </label>
        </div>
      )}
      <StartPasswordField
        id="new-start-password"
        value={startPassword}
        onChange={setStartPassword}
      />
      <button type="submit" disabled={create.isPending}>
        {create.isPending ? t('people.creating') : t('people.create')}
      </button>
      <p role="status" aria-live="polite" className="error">
        {error}
      </p>
    </form>
  );
}

export function PeoplePage() {
  const { t } = useTranslation();
  const session = useRequiredSession();
  const ownerPlants = useOwnerPlants(session.user.id);
  const [chosenPlant, setChosenPlant] = useState<string | null>(null);
  const [secret, setSecret] = useState<Secret | null>(null);
  const [status, setStatus] = useState('');

  const plants = ownerPlants.data ?? [];
  const plantId = chosenPlant ?? plants[0]?.id ?? null;

  const plant = plants.find((p) => p.id === plantId);
  const alertMemberships = useAlertMemberships(plant);
  const shiftOptions = useShiftOptions(plant?.id);
  const assignments = useAssignments(plant?.id);
  const people = useQuery({
    queryKey: ['people', plantId],
    enabled: plantId !== null,
    queryFn: () =>
      callManageUsers<{ people: Person[] }>({ action: 'list', plant_id: plantId as string }),
  });

  if (ownerPlants.isPending) return <p role="status">{t('common.loading')}</p>;

  return (
    <main className="form-page">
      <h1>{t('people.title')}</h1>

      {plantId === null ? (
        <p>{t('people.notOwner')}</p>
      ) : (
        <>
          {plants.length > 1 && (
            <div className="field">
              <label htmlFor="plant">{t('people.plantLabel')}</label>
              <select
                id="plant"
                value={plantId}
                onChange={(e) => {
                  setSecret(null);
                  setChosenPlant(e.target.value);
                }}
              >
                {plants.map((p) => (
                  <option key={p.id} value={p.id}>
                    {p.name}
                  </option>
                ))}
              </select>
            </div>
          )}

          {secret && <SecretBox secret={secret} onDone={() => setSecret(null)} />}

          <p role="status" aria-live="polite">
            {status}
          </p>

          <h2>{t('people.listTitle')}</h2>
          {people.isPending && <p role="status">{t('common.loading')}</p>}
          {people.isError && <p className="error">{t(errorKey(people.error))}</p>}
          {people.data && people.data.people.length === 0 && <p>{t('people.empty')}</p>}
          {people.data && (
            <ul className="people">
              {people.data.people.map((p) => (
                <PersonCard
                  key={p.user_id}
                  person={p}
                  selfId={session.user.id}
                  plantId={plantId}
                  plant={plant ?? { id: plantId, org_id: '' }}
                  alertMemberships={alertMemberships.data ?? []}
                  shifts={shiftOptions.data ?? []}
                  assignments={assignments.data ?? []}
                  onSecret={(s) => {
                    setStatus('');
                    setSecret(s);
                  }}
                  onStatus={setStatus}
                />
              ))}
            </ul>
          )}

          <CreateForm
            plantId={plantId}
            onSecret={(s) => {
              setStatus('');
              setSecret(s);
            }}
            onStatus={setStatus}
          />
        </>
      )}
    </main>
  );
}
