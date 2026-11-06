import { Link } from 'react-router';
import { useTranslation } from 'react-i18next';
import { IconWarning } from '../washroom/Icons';
import { useTasks } from './tasksData';

/** Pinned on Control home for a manager: how many of THEIR tasks are open (no one else's). */
export function MyTaskCount({ plantId }: { plantId: string }) {
  const { t } = useTranslation();
  const tasks = useTasks(plantId, false);
  const open = (tasks.data ?? []).filter((x) => !x.done_at).length;
  if (open === 0) return null;
  return (
    <p className="task-pinned">
      <IconWarning /> <Link to="/control/tasks">{t('tasks.pinned', { count: open })}</Link>
    </p>
  );
}
