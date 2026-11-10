import { useState } from 'react';
import { useTranslation } from 'react-i18next';
import { IconOffline } from '../washroom/Icons';
import { amountKey, type LogLine } from './finishedLogic';
import type { VoidReason } from './useFinishedOutbox';

// The selected item's lines this shift, newest first, with their times (plant time zone). Tap a line
// to take it off with a reason (wrong item / wrong number / duplicate): the line is voided, never
// deleted, and the totals update. A line still on the tablet is simply taken off the device.

const REASONS: readonly Exclude<VoidReason, 'undo'>[] = ['wrong_item', 'wrong_number', 'duplicate'];

export function ItemLog({
  lines,
  itemName,
  timeFmt,
  onVoid,
  onRemovePending,
}: {
  lines: readonly LogLine[];
  itemName: string;
  timeFmt: Intl.DateTimeFormat;
  onVoid: (line: LogLine, reason: Exclude<VoidReason, 'undo'>) => Promise<boolean>;
  onRemovePending: (line: LogLine) => Promise<boolean>;
}) {
  const { t, i18n } = useTranslation();
  const num = new Intl.NumberFormat(i18n.language);
  const [open, setOpen] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState<{ ok: boolean; text: string } | null>(null);
  const newest = [...lines].reverse();

  async function run(fn: () => Promise<boolean>) {
    setBusy(true);
    const ok = await fn();
    setBusy(false);
    setOpen(null);
    setMessage({ ok, text: ok ? t('finished.lineRemoved') : t('finished.lineRemoveFailed') });
  }

  return (
    <section className="card fg-log" aria-labelledby="fg-log-title">
      <h2 id="fg-log-title">{t('finished.logTitle', { name: itemName })}</h2>
      <div role="status" aria-live="polite">
        {message && <p className={message.ok ? 'notice' : 'error'}>{message.text}</p>}
      </div>
      {newest.length === 0 ? (
        <p className="hint">{t('finished.logEmpty')}</p>
      ) : (
        <ol className="fg-log-list">
          {newest.map((l) => {
            const a = amountKey(l.packs, l.loose, l.pieces);
            const amount = t(a.key, {
              packs: num.format(a.values.packs),
              loose: num.format(a.values.loose),
              pieces: num.format(a.values.pieces),
              count: a.values.count,
            });
            const time = timeFmt.format(new Date(l.occurredAt));
            const isOpen = open === l.key;
            return (
              <li key={l.key} className={l.pending ? 'fg-line pending' : 'fg-line'}>
                <button
                  type="button"
                  className="fg-line-btn"
                  aria-expanded={isOpen}
                  onClick={() => setOpen(isOpen ? null : l.key)}
                >
                  <span className="mono fg-line-time">{time}</span>
                  <span className="fg-line-amount">{amount}</span>
                  {l.pending && (
                    <span className="fg-line-pending">
                      <IconOffline /> {t('finished.onTablet')}
                    </span>
                  )}
                </button>
                {isOpen && (
                  <div
                    className="fg-line-actions"
                    role="group"
                    aria-label={t('finished.removeWhy')}
                  >
                    <p>{t('finished.removeWhy')}</p>
                    {l.id === null ? (
                      <button
                        type="button"
                        className="danger"
                        disabled={busy}
                        onClick={() => void run(() => onRemovePending(l))}
                      >
                        {t('finished.removeUnsent')}
                      </button>
                    ) : (
                      REASONS.map((r) => (
                        <button
                          key={r}
                          type="button"
                          className="danger"
                          disabled={busy}
                          onClick={() => void run(() => onVoid(l, r))}
                        >
                          {t(`finished.reasons.${r}`)}
                        </button>
                      ))
                    )}
                    <button
                      type="button"
                      className="secondary"
                      disabled={busy}
                      onClick={() => setOpen(null)}
                    >
                      {t('finished.keepLine')}
                    </button>
                  </div>
                )}
              </li>
            );
          })}
        </ol>
      )}
    </section>
  );
}
