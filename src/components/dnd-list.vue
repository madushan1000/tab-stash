<template>
  <component
    :is="is || 'ul'"
    :class="{'dnd-list': true, 'drag-in-progress': isDragging}"
    ref="$top"
    @dragenter="parentDragEnter"
    @dragover="itemDragOver"
    @drop="doDrop"
  >
    <template v-for="(item, index) of displayItems" :key="itemKey(item)">
      <component
        v-if="index === ghostIndex"
        :is="itemIs || 'li'"
        :style="index === ghostIndex && ghostStyle"
        :class="{
          'dnd-list-ghost': true,
          'dropping-here': index === ghostIndex,
        }"
        :data-key="itemKey(item)"
        @dragenter="ghostDragEnter($event, index)"
        @dragover="ghostDragOver($event)"
        @drop="doDrop"
      >
        <slot name="ghost" />
      </component>

      <component
        :is="itemIs || 'li'"
        :class="itemClassFor(item, index)"
        :data-key="itemKey(item)"
        ref="$dndElements"
        @mousedown.stop="enableDrag"
        @mouseup.stop="disableDrag"
        @dragstart="itemDragStart($event, index)"
        @dragend="itemDragEnd"
        @dragenter="itemDragEnter($event, index)"
        @dragover="itemDragOver"
        @drop="doDrop"
      >
        <slot name="item" :item="item" />
      </component>
    </template>

    <component
      :is="itemIs || 'li'"
      :style="ghostIndex === displayItems.length && ghostStyle"
      :class="{
        // NOTE: This ghost must always be present when dragging so we have a
        // drop target for the end of the list.  Otherwise, it's impossible for
        // a user to drag a ghost to the end of the list unless the list has
        // some padding at the end.
        'dnd-list-ghost': true,
        'dropping-here': ghostIndex === displayItems.length,
      }"
      @dragenter="ghostDragEnter($event, displayItems.length)"
      @dragover="ghostDragOver($event)"
      @drop="doDrop"
    >
      <slot name="ghost" />
    </component>
  </component>
</template>

<script lang="ts">
import {computed, nextTick, reactive, ref} from "vue";

import type {DragAction, DropAction} from "./dnd-list";

type ListState<I = unknown> = {
  modelSnapshot: undefined | readonly I[];
  readonly modelValue: readonly I[];
};

type DragLocation = {
  /** The DndList containing the drag/drop location */
  parent: ListState;

  /** The index of the drag/drop location in the DndList's modelValue. */
  index: number;
};

// This rather ugly global variable maintains the state of a DnD operation, of
// which only one should ever be happening at a time.
const DND = reactive({
  /** Where are we dragging from?  (If known/part of this page.) */
  dragging: undefined as undefined | DragLocation,

  /** Where are we dragging to?  (If we have a valid drop target.) */
  dropping: undefined as undefined | DragLocation,

  /** An in-progress drop operation--once the user releases the mouse button,
   * we start the async drop() function, and while it's running, this is set
   * to the drop action. */
  dropTask: undefined as undefined | DropAction,

  /** Width/height the ghost should adopt to avoid flickering/awkward
   * reflowing when it moves. */
  ghostStyle: undefined as undefined | {width: number; height: number},
});
</script>

<script setup lang="ts" generic="I">
const props = defineProps<{
  is?: string;
  itemIs?: string;
  itemKey: (item: I) => string | number;
  itemClass?: (item: I, index: number) => Record<string, boolean>;
  accepts: string | readonly string[];
  modelValue: I[];

  drag: (drag: DragAction<I>) => void;
  drop: (drop: DropAction) => Promise<void>;

  /** When the ghost is displayed, does it cause items to change their positions
   * on the screen? */
  ghostDisplacesItems?: boolean;

  /** Should the ghost mimic the height of the item it's replacing? */
  ghostMimicsWidth?: boolean;

  /** Should the ghost mimic the width of the item it's replacing? */
  ghostMimicsHeight?: boolean;
}>();

const $top = ref(undefined! as HTMLElement);
const $dndElements = ref([] as HTMLElement[]);

/** State shared between dnd-list components so they can coordinate */
const state: ListState<I> = reactive({
  /** A snapshot of the model saved before beginning an actual drop operation,
   * which is shown to the user until the drop operation completes.  This
   * buffering ensures the user doesn't see any flickering during the drop. */
  modelSnapshot: undefined,
  modelValue: computed(() => props.modelValue),
});

const isDragging = computed((): boolean => {
  return !!DND.dropping;
});

const draggingIndex = computed((): number | undefined => {
  if (!DND.dragging) return undefined;
  if (DND.dragging.parent !== state) return undefined;
  return DND.dragging.index;
});

const ghostIndex = computed((): number | undefined => {
  // Show where the item came from if we can't drop it anywhere
  if (!DND.dropping) return draggingIndex.value;
  if (DND.dropping.parent !== state) return undefined;
  return DND.dropping.index;
});

const ghostStyle = computed((): string | undefined => {
  const s = DND.ghostStyle;
  if (!s) return undefined;

  let style = "";
  if (props.ghostMimicsWidth) style += `width: ${s.width}px; `;
  if (props.ghostMimicsHeight) style += `height: ${s.height}px; `;
  return style || undefined;
});

const displayItems = computed((): readonly I[] => {
  return state.modelSnapshot ?? props.modelValue;
});

function itemClassFor(item: I, index: number): Record<string, boolean> {
  const classes = props.itemClass ? props.itemClass(item, index) : {};
  classes.dragging =
    DND.dragging?.parent === state && DND.dragging?.index === index;
  return classes;
}

/** Given a DOM Event, locate the corresponding element in the DOM for
 * the DnD item. */
function dndElement(ev: Event): HTMLElement | undefined {
  if (!($dndElements.value instanceof Array)) return;
  let t = ev.target;
  while (t instanceof HTMLElement) {
    if ($dndElements.value.includes(t)) return t;
    t = t.parentElement;
  }
  return undefined;
}

/** We only set `draggable="true"` on the dragged element when we
 * actually want to start dragging.  This allows for children of the
 * draggable element to intercept mousedown events to prevent dragging,
 * so that such children can be interacted with. */
function enableDrag(ev: DragEvent) {
  const el = dndElement(ev);
  if (el) el.draggable = true;
}

/** Undo the effect of enableDrag() -- see that method for details. */
function disableDrag(ev: DragEvent) {
  const el = dndElement(ev);
  if (el) el.draggable = false;
}

/** Fired on the source location at the very beginning/end of the op */
function itemDragStart(ev: DragEvent, index: number) {
  const dndEl = dndElement(ev);

  // Now that the drag has started, undo the effect of enableDrag() as
  // explained there.
  disableDrag(ev);
  ev.stopPropagation();

  if (DND.dropTask) {
    // Only one DnD operation is allowed at a time.
    ev.preventDefault();
    return;
  }

  props.drag({
    dataTransfer: ev.dataTransfer!,
    fromIndex: index,
    value: props.modelValue[index],
  });

  // setTimeout() to work around a Chrome bug described here:
  // https://stackoverflow.com/questions/19639969/html5-dragend-event-firing-immediately
  setTimeout(() => {
    if (!dndEl) return;

    const rect = dndEl.getBoundingClientRect();
    DND.dragging = {parent: state, index};
    DND.dropping = {parent: state, index};
    DND.ghostStyle = {width: rect.width, height: rect.height};
  });
}

/** Fired on the source location at the end of a drag op (regardless of
 * whether it was committed or aborted). */
function itemDragEnd() {
  // If a drop operation is committed/in progress, we don't clear the
  // DND until it actually completes.
  if (DND.dropTask) return;
  DND.dragging = undefined;
  DND.dropping = undefined;
  DND.ghostStyle = undefined;
}

/** Fired when an item that is being dragged enters an element. */
function itemDragEnter(ev: DragEvent, index: number) {
  if (!allowDropHere(ev)) return;

  // Make the ghost mimic the size of the element it's about to enter,
  // as a way of debouncing.  This (mostly) guarantees that the ghost
  // will remain under the mouse cursor when it moves to its new
  // position, avoiding constant flickering/reshuffling if the ghost
  // enters/leaves a particular position as a result of the list being
  // re-flowed after moving the ghost.
  const el = dndElement(ev);
  if (el) {
    const rect = el.getBoundingClientRect();
    DND.ghostStyle = {width: rect.width, height: rect.height};
  }

  moveGhost(index);
}

/** Fired periodically while an element is being hovered over as a
 * potential drop target.  For stupid browser reasons, we must implement
 * both this AND dragEnter to let the browser know whether the element
 * is (still) a valid drop target. */
function itemDragOver(ev: DragEvent) {
  allowDropHere(ev); // called just for its side-effects
}

/** Special dragEnter events for parent items, which need different
 * behavior in Firefox because Firefox likes to fire these events even
 * when a child element should be consuming them instead... */
function parentDragEnter(ev: DragEvent) {
  if (!allowDropHere(ev)) return;
  if (ev.target && ev.target !== $top.value) return;
  moveGhost(displayItems.value.length);
}

/** Fired on the "ghost" element when the cursor enters it (e.g. because
 * it was moved to be under the cursor, to indicate where the item will
 * be dropped). */
function ghostDragEnter(ev: DragEvent, index: number) {
  if (props.ghostDisplacesItems) {
    ev.preventDefault(); // allow dropping here
    ev.stopPropagation(); // consume the (potential) drop
  } else {
    itemDragEnter(ev, index);
  }
}

/** Fired on the "ghost" element repeatedly while the cursor is inside
 * it.  Just like itemDragOver(), we only want to spend enough time to
 * let the browser know this is a valid drop target.  (We determined
 * this earlier before moving the ghost into place.) */
function ghostDragOver(ev: DragEvent) {
  if (props.ghostDisplacesItems) {
    ev.preventDefault(); // allow dropping here
    ev.stopPropagation(); // consume the (potential) drop
  } else {
    itemDragOver(ev);
  }
}

/** Rejects the potential drop operation if this isn't a suitable
 * location for the drag that's in progress. */
function allowDropHere(ev: DragEvent): boolean {
  if (!ev.dataTransfer) return false;
  const types = ev.dataTransfer.types;
  if (props.accepts instanceof Array) {
    if (!types.find(t => props.accepts!.includes(t))) return false;
  } else if (props.accepts) {
    if (!types.includes(props.accepts)) return false;
  } else {
    return false;
  }
  ev.preventDefault();
  ev.stopPropagation();
  return true;
}

/** Moves the ghost to the specified location (sort of).  We want the
 * ghost to appear at `index`, which is presumed to be the location
 * currently under the mouse cursor.  (The actual index of the ghost may
 * vary depending on how it's being moved.) */
function moveGhost(index: number) {
  // NOTE: This is performance-critical code -- in particular,
  // updating `DND` in the wrong way may cause cascading unintended
  // updates across ALL <dnd-list> components in the page.

  if (ghostIndex.value !== undefined && ghostIndex.value <= index) {
    // If we are moving the ghost forward in the list from where it
    // currently is, we need to account for the fact that it's being
    // removed from its previous location, or it will appear at the
    // entry prior to where the mouse cursor actually is.
    if (props.ghostDisplacesItems) index++;
  }
  index = Math.min(index, displayItems.value.length);

  // PERFORMANCE: If we're only switching indexes in the same parent,
  // make sure that's the only field we touch.  Otherwise Vue will
  // update every single <dnd-list> in the page.
  if (DND.dropping) {
    if (DND.dropping.parent !== state) DND.dropping.parent = state;
    if (DND.dropping.index !== index) DND.dropping.index = index;
  } else {
    DND.dropping = {parent: state, index};
  }
}

/** Fired when it's time to actually perform the drop operation. */
function doDrop(ev: DragEvent) {
  if (!allowDropHere(ev)) return;
  if (!DND.dropping) return;

  ev.stopPropagation();

  const offset =
    DND.dragging?.parent === DND.dropping.parent &&
    (DND.dragging?.index || 0) < DND.dropping.index
      ? 0
      : 0;

  // Here we start the (async) drop task, and freeze the model in both
  // the source and destination lists until the drop task completes.
  // (We do this by taking a snapshot of the current modelValue and
  // storing it in modelSnapshot.) If we don't freeze the model, the
  // user will see a momentary flicker where the model(s) snap back to
  // the pre-drag state as both model values get updated.

  console.assert(DND.dropping?.parent === state);

  const drop_ev: DropAction = {
    dataTransfer: ev.dataTransfer!,
    toIndex: DND.dropping.index - offset,
  };
  DND.dropTask = drop_ev;
  if (DND.dragging?.parent) {
    DND.dragging.parent.modelSnapshot = Array.from(
      DND.dragging.parent.modelValue,
    );
  }
  state.modelSnapshot = Array.from(props.modelValue);
  props
    .drop(drop_ev)
    .then(() => nextTick()) // wait for Vue model updates
    .catch(console.error)
    .finally(() => {
      if (DND.dragging?.parent) {
        DND.dragging.parent.modelSnapshot = undefined;
      }
      DND.dragging = undefined;
      DND.dropping = undefined;
      DND.dropTask = undefined;
      DND.ghostStyle = undefined;
      state.modelSnapshot = undefined;
    });
}
</script>
