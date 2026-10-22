import {
  Column,
  CreateDateColumn,
  ForeignKeyColumn,
  type Generated,
  PrimaryGeneratedColumn,
  Table,
  Timestamp,
  Trigger,
  Unique,
  UpdateDateColumn,
} from '@immich/sql-tools';
import { UpdateIdColumn, UpdatedAtTrigger } from 'src/decorators.js';
import { AssetFileType } from 'src/enum.js';
import { gallery_lock_asset_file_path } from 'src/schema/functions.js';
import { AssetTable } from 'src/schema/tables/asset.table.js';

@Table('asset_file')
// Preserve the migration-owned UPDATE OF path guard; sql-tools has no column-event model.
// Its enabled database definition is asserted by schema-cli-compat.spec.ts.
@Trigger({
  name: 'gallery_lock_asset_file_path',
  timing: 'before',
  actions: ['insert', 'update'],
  scope: 'row',
  functionName: gallery_lock_asset_file_path.name,
  synchronize: false,
})
@Unique({ columns: ['assetId', 'type', 'isEdited'] })
@UpdatedAtTrigger('asset_file_updatedAt')
export class AssetFileTable {
  @PrimaryGeneratedColumn()
  id!: Generated<string>;

  @ForeignKeyColumn(() => AssetTable, { onDelete: 'CASCADE', onUpdate: 'CASCADE' })
  assetId!: string;

  @CreateDateColumn()
  createdAt!: Generated<Timestamp>;

  @UpdateDateColumn()
  updatedAt!: Generated<Timestamp>;

  @Column()
  type!: AssetFileType;

  @Column()
  path!: string;

  @UpdateIdColumn({ index: true })
  updateId!: Generated<string>;

  @Column({ type: 'boolean', default: false })
  isEdited!: Generated<boolean>;

  @Column({ type: 'boolean', default: false })
  isProgressive!: Generated<boolean>;

  @Column({ type: 'boolean', default: false })
  isTransparent!: Generated<boolean>;
}
