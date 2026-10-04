import {
  Column,
  CreateDateColumn,
  ForeignKeyColumn,
  type Generated,
  Index,
  PrimaryGeneratedColumn,
  Table,
  type Timestamp,
} from '@immich/sql-tools';
import { MemoryTable } from 'src/schema/tables/memory.table.js';
import { UserTable } from 'src/schema/tables/user.table.js';

@Table('memory_candidate')
@Index({ name: 'memory_candidate_owner_fingerprint_uq', columns: ['ownerId', 'fingerprint'], unique: true })
export class MemoryCandidateTable {
  @PrimaryGeneratedColumn()
  id!: Generated<string>;

  @ForeignKeyColumn(() => UserTable, { onDelete: 'CASCADE', index: true })
  ownerId!: string;

  @ForeignKeyColumn(() => MemoryTable, { onDelete: 'SET NULL', nullable: true, index: true })
  memoryId!: string | null;

  @Column()
  fingerprint!: string;

  @Column({ type: 'jsonb' })
  assetIds!: string[];

  @Column()
  state!: 'pending' | 'saved' | 'dismissed';

  @Column({ type: 'timestamp with time zone' })
  remindAt!: Timestamp;

  @CreateDateColumn()
  createdAt!: Generated<Timestamp>;
}
