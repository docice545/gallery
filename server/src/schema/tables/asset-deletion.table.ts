import {
  Check,
  Column,
  CreateDateColumn,
  ForeignKeyColumn,
  type Generated,
  Index,
  PrimaryColumn,
  Table,
  type Timestamp,
} from '@immich/sql-tools';
import { UserTable } from 'src/schema/tables/user.table.js';

export interface DeletionFile {
  path: string;
  root: string;
  rootDevice: string;
  rootInode: string;
  device: string;
  inode: string;
  size: string;
  modified: string;
  sha256: string;
  sha1: string;
}

@Table('asset_deletion_policy')
export class AssetDeletionPolicyTable {
  @ForeignKeyColumn(() => UserTable, { primary: true, onDelete: 'CASCADE', index: false })
  ownerId!: string;

  @PrimaryColumn({ type: 'text' })
  scope!: string;

  @Column({ type: 'boolean', default: false })
  enabled!: Generated<boolean>;

  @Column({ type: 'jsonb' })
  roots!: string[];

  @Column({ type: 'text' })
  recoveryProof!: string;

  @Column({ type: 'text' })
  authorizedBy!: string;

  @CreateDateColumn()
  updatedAt!: Generated<Timestamp>;
}

// No asset/library foreign key: this record MUST survive removal of either index row.
@Table('asset_deletion_tombstone')
@Check({
  name: 'asset_deletion_tombstone_state_check',
  expression: "state IN ('preparing', 'pending', 'failed', 'files-removed', 'complete')",
})
@Index({ name: 'asset_deletion_owner_checksum', columns: ['ownerId', 'checksum'] })
@Index({ name: 'asset_deletion_library_path', columns: ['libraryId', 'originalPath'] })
export class AssetDeletionTombstoneTable {
  @PrimaryColumn({ type: 'uuid' })
  assetId!: string;

  @ForeignKeyColumn(() => UserTable, { onDelete: 'CASCADE', index: true })
  ownerId!: string;

  @Column({ type: 'uuid', nullable: true })
  libraryId!: string | null;

  @Column({ type: 'uuid' })
  operationId!: string;

  @Column({ type: 'text' })
  scope!: string;

  @Column({ type: 'text' })
  originalPath!: string;

  @Column({ type: 'bytea' })
  checksum!: Buffer;

  @Column({ type: 'text' })
  checksumAlgorithm!: string;

  @Column({ type: 'bytea' })
  contentChecksum!: Buffer;

  @Column({ type: 'jsonb' })
  aliases!: string[];

  @Column({ type: 'jsonb' })
  authorization!: { actor: string; recoveryProof: string; policyUpdatedAt: string };

  @Column({ type: 'jsonb' })
  files!: DeletionFile[];

  @Column({ type: 'text' })
  state!: 'preparing' | 'pending' | 'failed' | 'files-removed' | 'complete';

  @Column({ type: 'text', nullable: true })
  errorCode!: string | null;

  @CreateDateColumn()
  createdAt!: Generated<Timestamp>;
}
