import { ConflictException, Injectable } from '@nestjs/common';
import { OnEvent, OnJob } from 'src/decorators.js';
import { BulkIdsDto } from 'src/dtos/asset-ids.response.dto.js';
import { AuthDto } from 'src/dtos/auth.dto.js';
import { TrashResponseDto } from 'src/dtos/trash.dto.js';
import { JobName, JobStatus, Permission, QueueName } from 'src/enum.js';
import { BaseService } from 'src/services/base.service.js';

@Injectable()
export class TrashService extends BaseService {
  async restoreAssets(auth: AuthDto, dto: BulkIdsDto): Promise<TrashResponseDto> {
    const { ids } = dto;
    if (ids.length === 0) {
      return { count: 0 };
    }

    await this.requireAccess({ auth, permission: Permission.AssetDelete, ids });
    const restoredIds = await this.trashRepository.restoreAll(ids);
    if (restoredIds.length > 0) {
      await this.duplicateRepository.deleteConflictingTombstones(auth.user.id, restoredIds);
      await this.eventRepository.emit('AssetRestoreAll', { assetIds: restoredIds, userId: auth.user.id });
    }

    this.logger.log(`Restored ${restoredIds.length} asset(s) from trash`);

    return { count: restoredIds.length };
  }

  async restore(auth: AuthDto): Promise<TrashResponseDto> {
    const count = await this.trashRepository.restore(auth.user.id);
    if (count > 0) {
      await this.duplicateRepository.deleteConflictingTombstonesForUser(auth.user.id);
      this.logger.log(`Restored ${count} asset(s) from trash`);
    }
    return { count };
  }

  empty(_auth: AuthDto): Promise<TrashResponseDto> {
    return Promise.reject(
      new ConflictException('Select trashed assets for explicit library-authorized permanent deletion.'),
    );
  }

  @OnEvent({ name: 'AssetDeleteAll' })
  async onAssetsDelete() {
    await this.jobRepository.queue({ name: JobName.AssetEmptyTrash, data: {} });
  }

  @OnJob({ name: JobName.AssetEmptyTrash, queue: QueueName.BackgroundTask })
  handleEmptyTrash() {
    // Explicit permanent deletion uses the existing worker with a durable authorization receipt.
    // Retention and legacy empty-trash jobs never activate original-file deletion.
    return Promise.resolve(JobStatus.Skipped);
  }
}
