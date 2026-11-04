<script lang="ts">
  import type { TimelineAsset } from '$lib/managers/timeline-manager/types';

  const { asset, onClick, onMouseEvent } = $props<{
    asset: TimelineAsset;
    onClick: () => void;
    onMouseEvent: (event: { isMouseOver: boolean; selectedGroupIndex: number }) => void;
  }>();
</script>

<button
  type="button"
  data-testid={`stack-frame-${asset.id}`}
  onclick={onClick}
  onmouseenter={() => onMouseEvent({ isMouseOver: true, selectedGroupIndex: 0 })}
  onmouseleave={() => onMouseEvent({ isMouseOver: false, selectedGroupIndex: 0 })}
>
  {asset.id}
</button>
