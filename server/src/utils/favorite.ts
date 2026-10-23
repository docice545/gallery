import { BadRequestException } from '@nestjs/common';
import { sql } from 'kysely';
import { AuthDto } from 'src/dtos/auth.dto.js';
import { asUuid } from 'src/utils/database.js';

// Correlated per-user overlay, also valid inside timeline CTEs. Identifiers are internal constants.
export function favoriteExistsFor(_eb: unknown, userId: string, assetIdRef = 'asset.id') {
  return sql<boolean>`exists (select 1 from asset_favorite
    where asset_favorite."assetId" = ${sql.ref(assetIdRef)}
      and asset_favorite."userId" = ${asUuid(userId)})`;
}

// A shared-link visitor is not the link owner whose identity is stored in auth.user.
export const rejectSharedLinkFavoriteFilter = (auth: AuthDto, isFavorite: boolean | undefined | null) => {
  if (auth.sharedLink && isFavorite !== undefined && isFavorite !== null) {
    throw new BadRequestException('Shared link sessions cannot filter by favorite');
  }
};
