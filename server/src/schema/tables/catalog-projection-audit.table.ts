import { CreateDateColumn, type Generated, Table, Timestamp } from '@immich/sql-tools';
import { PrimaryGeneratedUuidV7Column } from 'src/decorators.js';

// Server-only cache invalidation, never a deletion receipt or an AssetDelete event.
@Table('catalog_projection_audit')
export class CatalogProjectionAuditTable {
  @PrimaryGeneratedUuidV7Column()
  id!: Generated<string>;

  @CreateDateColumn({ default: () => 'clock_timestamp()', index: true })
  deletedAt!: Generated<Timestamp>;
}
