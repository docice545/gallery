<script lang="ts">
  import type { AssetResponseDto, StackResponseDto } from '@immich/sdk';
  import type { OnUndoDelete } from '$lib/utils/actions';
  import type { OnAction, PreAction } from '../actions/action';
  import DeleteAction from '../actions/DeleteAction.svelte';

  const { asset, stack, onAction, preAction, onUndoDelete } = $props<{
    asset: AssetResponseDto;
    stack: StackResponseDto | null;
    onAction: OnAction;
    preAction: PreAction;
    onUndoDelete?: OnUndoDelete;
  }>();
</script>

<span data-testid="viewed-frame">{asset.id}</span>
{#if stack}
  <span data-testid="stack-size">{stack.assets.length}</span>
{/if}
<DeleteAction {asset} {onAction} {preAction} {onUndoDelete} />
