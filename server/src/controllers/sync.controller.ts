import { Body, Controller, Delete, Get, Header, HttpCode, HttpStatus, Post, Req, Res } from '@nestjs/common';
import { ApiResponse, ApiTags } from '@nestjs/swagger';
import type { Request, Response } from 'express';
import type { AuthDto } from 'src/dtos/auth.dto.js';
import { Endpoint, HistoryBuilder } from 'src/decorators.js';
import { SyncAckDeleteDto, SyncAckDto, SyncAckSetDto, SyncAckV2Dto, SyncStreamDto } from 'src/dtos/sync.dto.js';
import { ApiTag, Permission } from 'src/enum.js';
import { Auth, Authenticated } from 'src/middleware/auth.guard.js';
import { GlobalExceptionFilter } from 'src/middleware/global-exception.filter.js';
import { SyncService } from 'src/services/sync.service.js';

@ApiTags(ApiTag.Sync)
@Controller('sync')
export class SyncController {
  constructor(
    private service: SyncService,
    private errorService: GlobalExceptionFilter,
  ) {}

  @Post('stream')
  @Authenticated({ permission: Permission.SyncStream })
  @Header('Content-Type', 'application/jsonlines+json')
  @HttpCode(HttpStatus.OK)
  @Endpoint({
    summary: 'Stream sync changes',
    description:
      'Retrieve a JSON lines streamed response of changes for synchronization. This endpoint is used by the mobile app to efficiently stay up to date with changes.',
    history: new HistoryBuilder().added('v1').beta('v1').stable('v2'),
  })
  async getSyncStream(@Auth() auth: AuthDto, @Req() req: Request, @Res() res: Response, @Body() dto: SyncStreamDto) {
    try {
      await this.service.stream(auth, res, dto);
    } catch (error: Error | any) {
      this.errorService.handleError(req, res, error);
    }
  }

  @Get('ack')
  @ApiResponse({ status: HttpStatus.CONFLICT, description: 'Extended sync checkpoints require GET /sync/ack/v2' })
  @Authenticated({ permission: Permission.SyncCheckpointRead })
  @Endpoint({
    summary: 'Retrieve acknowledgements',
    description: 'Retrieve the synchronization acknowledgments for the current session.',
    history: new HistoryBuilder().added('v1').beta('v1').stable('v2'),
  })
  getSyncAck(@Auth() auth: AuthDto): Promise<SyncAckDto[]> {
    return this.service.getAcks(auth);
  }

  @Get('ack/v2')
  @Authenticated({ permission: Permission.SyncCheckpointRead })
  @Endpoint({
    summary: 'Retrieve acknowledgements including extended sync protocols',
    description:
      'Returns all checkpoints for the current session without projection or aliasing. Legacy GET /sync/ack returns 409 when extended checkpoints are present; use this versioned endpoint for such sessions. Stream and acknowledgement writes are unchanged.',
    history: new HistoryBuilder().added('v5.7.3'),
  })
  getSyncAckV2(@Auth() auth: AuthDto): Promise<SyncAckV2Dto[]> {
    return this.service.getAcksV2(auth);
  }

  @Post('ack')
  @Authenticated({ permission: Permission.SyncCheckpointUpdate })
  @HttpCode(HttpStatus.NO_CONTENT)
  @Endpoint({
    summary: 'Acknowledge changes',
    description:
      'Send a list of synchronization acknowledgements to confirm that the latest changes have been received.',
    history: new HistoryBuilder().added('v1').beta('v1').stable('v2'),
  })
  sendSyncAck(@Auth() auth: AuthDto, @Body() dto: SyncAckSetDto) {
    return this.service.setAcks(auth, dto);
  }

  @Delete('ack')
  @Authenticated({ permission: Permission.SyncCheckpointDelete })
  @HttpCode(HttpStatus.NO_CONTENT)
  @Endpoint({
    summary: 'Delete acknowledgements',
    description: 'Delete specific synchronization acknowledgments.',
    history: new HistoryBuilder().added('v1').beta('v1').stable('v2'),
  })
  deleteSyncAck(@Auth() auth: AuthDto, @Body() dto: SyncAckDeleteDto): Promise<void> {
    return this.service.deleteAcks(auth, dto);
  }
}
