import { useMemo, type ReactNode } from 'react';
import { useTranslation } from 'react-i18next';
import {
  closestCenter,
  DndContext,
  KeyboardSensor,
  MouseSensor,
  TouchSensor,
  useSensor,
  useSensors,
  type Announcements,
  type CollisionDetection,
  type DragEndEvent,
  type Modifier,
  type UniqueIdentifier,
} from '@dnd-kit/core';
import {
  SortableContext,
  sortableKeyboardCoordinates,
  useSortable,
  verticalListSortingStrategy,
} from '@dnd-kit/sortable';
import { CSS } from '@dnd-kit/utilities';
import { dropAfterId, samePartition, type Orderable } from './queueOrder';

// Drag to reorder (owner 2026-11-09: "drag the current work to place in the correct order").
// - Only the handle starts a drag: a mouse after 4 px, a finger after a short press-and-hold
//   (250 ms) so the phone still scrolls, the keyboard with Space/Enter + arrows (announced, i18n).
// - Drop targets are limited to the item's own RUSH / normal partition (mirrors reorder_queue_item),
//   so a normal item can't be dragged above RUSH work.
// - The up/down/top/position buttons in each item's actions are the non-drag alternative (WCAG 2.5.7).

/** Vertical only: the list is one column (no @dnd-kit/modifiers dependency for one line). */
const verticalOnly: Modifier = ({ transform }) => ({ ...transform, x: 0 });

function prefersReducedMotion(): boolean {
  return (
    typeof window !== 'undefined' &&
    !!window.matchMedia?.('(prefers-reduced-motion: reduce)').matches
  );
}

/** Six-dot grip (decorative; the button carries the words). */
function IconGrip() {
  return (
    <svg
      className="icon"
      width="1.5em"
      height="1.5em"
      viewBox="0 0 24 24"
      aria-hidden="true"
      focusable="false"
    >
      {[6, 12, 18].map((y) =>
        [9, 15].map((x) => <circle key={`${x}-${y}`} cx={x} cy={y} r="1.8" fill="currentColor" />),
      )}
    </svg>
  );
}

function SortableRow({
  id,
  disabled,
  className,
  render,
}: {
  id: string;
  disabled: boolean;
  className: string;
  render: (handle: ReactNode) => ReactNode;
}) {
  const { t } = useTranslation();
  const {
    attributes,
    listeners,
    setNodeRef,
    setActivatorNodeRef,
    transform,
    transition,
    isDragging,
  } = useSortable({ id, disabled });
  const label = t('queue.dragHandle');
  // Visible tooltip + aria-label with the same words (Voice Control: "tap Drag to reorder").
  const handle = disabled ? null : (
    <button
      type="button"
      ref={setActivatorNodeRef}
      className="q-handle"
      title={label}
      {...attributes}
      {...listeners}
      aria-label={label}
    >
      <IconGrip />
    </button>
  );
  return (
    <li
      ref={setNodeRef}
      className={isDragging ? `${className} dragging` : className}
      style={{
        transform: CSS.Translate.toString(transform),
        transition: prefersReducedMotion() ? undefined : transition,
      }}
    >
      {render(handle)}
    </li>
  );
}

export function SortableQueueList<T extends Orderable>({
  items,
  enabled,
  label,
  itemLabel,
  placeOf,
  rowClass,
  renderItem,
  onDrop,
}: {
  items: readonly T[];
  /** Owner, "All" filter, nothing saving: rows get a handle. */
  enabled: boolean;
  label: string;
  /** "#3 Black mats", for the screen-reader announcements. */
  itemLabel: (id: string) => string;
  placeOf: (id: string) => number;
  rowClass: (item: T) => string;
  /** Renders a row; `handle` is the drag handle button (null when dragging is off). */
  renderItem: (item: T, handle: ReactNode) => ReactNode;
  onDrop: (item: T, afterId: string | null) => void;
}) {
  const { t } = useTranslation();
  const sensors = useSensors(
    useSensor(MouseSensor, { activationConstraint: { distance: 4 } }),
    useSensor(TouchSensor, { activationConstraint: { delay: 250, tolerance: 8 } }),
    useSensor(KeyboardSensor, { coordinateGetter: sortableKeyboardCoordinates }),
  );
  const ids = useMemo(() => items.map((i) => i.id), [items]);

  // Only same-partition rows are targets (also used by the keyboard sensor's arrow keys).
  const collision: CollisionDetection = (args) =>
    closestCenter({
      ...args,
      droppableContainers: args.droppableContainers.filter((c) =>
        samePartition(items, String(args.active.id), String(c.id)),
      ),
    });

  const name = (id: UniqueIdentifier) => itemLabel(String(id));
  const announcements: Announcements = {
    onDragStart: ({ active }) => t('queue.dnd.picked', { item: name(active.id) }),
    onDragOver: ({ active, over }) =>
      over
        ? t('queue.dnd.over', { item: name(active.id), place: placeOf(String(over.id)) })
        : t('queue.dnd.overNone', { item: name(active.id) }),
    onDragEnd: ({ active, over }) =>
      over && over.id !== active.id
        ? t('queue.dnd.dropped', { item: name(active.id), place: placeOf(String(over.id)) })
        : t('queue.dnd.droppedNone', { item: name(active.id) }),
    onDragCancel: ({ active }) => t('queue.dnd.cancelled', { item: name(active.id) }),
  };

  function onDragEnd({ active, over }: DragEndEvent) {
    const item = items.find((i) => i.id === active.id);
    if (!item || !over) return;
    const afterId = dropAfterId(items, item.id, String(over.id));
    if (afterId !== undefined) onDrop(item, afterId);
  }

  return (
    <DndContext
      sensors={sensors}
      collisionDetection={collision}
      modifiers={[verticalOnly]}
      onDragEnd={onDragEnd}
      accessibility={{
        announcements,
        screenReaderInstructions: { draggable: t('queue.dnd.instructions') },
      }}
    >
      <SortableContext items={ids} strategy={verticalListSortingStrategy} disabled={!enabled}>
        <ol className="queue-list" aria-label={label}>
          {items.map((item) => (
            <SortableRow
              key={item.id}
              id={item.id}
              disabled={!enabled}
              className={rowClass(item)}
              render={(handle) => renderItem(item, handle)}
            />
          ))}
        </ol>
      </SortableContext>
    </DndContext>
  );
}
