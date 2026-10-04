import { CreateDateColumn, ForeignKeyColumn, type Generated, Table, type Timestamp } from '@immich/sql-tools';
import { AssetTable } from 'src/schema/tables/asset.table.js';
import { UserTable } from 'src/schema/tables/user.table.js';

@Table('stack_suppression')
export class StackSuppressionTable {
  @ForeignKeyColumn(() => AssetTable, { primary: true, onDelete: 'CASCADE', index: false })
  assetId!: string;

  @ForeignKeyColumn(() => UserTable, { onDelete: 'CASCADE', index: true })
  ownerId!: string;

  @CreateDateColumn()
  createdAt!: Generated<Timestamp>;
}
