import { Body, Controller, Delete, Get, HttpCode, HttpStatus, Next, Param, Post, Res } from '@nestjs/common';
import { ApiTags } from '@nestjs/swagger';
import type { NextFunction, Response } from 'express';
import type { AuthDto } from 'src/dtos/auth.dto.js';
import { Endpoint, HistoryBuilder } from 'src/decorators.js';
import { AssetMediaResponseDto } from 'src/dtos/asset-media-response.dto.js';
import {
  MagicEraserCapabilitiesDto,
  MagicEraserCreateDto,
  MagicEraserJobParamsDto,
  MagicEraserJobResponseDto,
} from 'src/dtos/magic-eraser.dto.js';
import { ApiTag, Permission } from 'src/enum.js';
import { Auth, Authenticated, FileResponse } from 'src/middleware/auth.guard.js';
import { LoggingRepository } from 'src/repositories/logging.repository.js';
import { MagicEraserService } from 'src/services/magic-eraser.service.js';
import { sendFile } from 'src/utils/file.js';
import { UUIDParamDto } from 'src/validation.js';

@ApiTags(ApiTag.Assets)
@Controller('assets')
export class MagicEraserController {
  constructor(
    private service: MagicEraserService,
    private logger: LoggingRepository,
  ) {}

  @Get(':id/magic-eraser/capabilities')
  @Authenticated({ permission: Permission.AssetEditGet })
  @Endpoint({ summary: 'Get private Magic Eraser availability', history: new HistoryBuilder().added('v1').beta('v1') })
  getMagicEraserCapabilities(
    @Auth() auth: AuthDto,
    @Param() { id }: UUIDParamDto,
  ): Promise<MagicEraserCapabilitiesDto> {
    return this.service.capabilities(auth, id);
  }

  @Get(':id/magic-eraser/source')
  @FileResponse()
  @Authenticated({ permission: Permission.AssetEditGet })
  @Endpoint({ summary: 'Get oriented original editor preview', history: new HistoryBuilder().added('v1').beta('v1') })
  async getMagicEraserSource(
    @Auth() auth: AuthDto,
    @Param() { id }: UUIDParamDto,
    @Res() res: Response,
    @Next() next: NextFunction,
  ) {
    await sendFile(res, next, () => this.service.source(auth, id), this.logger);
  }

  @Post(':id/magic-eraser')
  @HttpCode(HttpStatus.ACCEPTED)
  @Authenticated({ permission: Permission.AssetEditCreate })
  @Endpoint({
    summary: 'Process a brush mask on an owned original',
    history: new HistoryBuilder().added('v1').beta('v1'),
  })
  createMagicEraserJob(
    @Auth() auth: AuthDto,
    @Param() { id }: UUIDParamDto,
    @Body() dto: MagicEraserCreateDto,
  ): Promise<MagicEraserJobResponseDto> {
    return this.service.create(auth, id, dto);
  }

  @Get(':id/magic-eraser/:jobId')
  @Authenticated({ permission: Permission.AssetEditGet })
  @Endpoint({ summary: 'Get private Magic Eraser job status', history: new HistoryBuilder().added('v1').beta('v1') })
  getMagicEraserJob(
    @Auth() auth: AuthDto,
    @Param() { id, jobId }: MagicEraserJobParamsDto,
  ): Promise<MagicEraserJobResponseDto> {
    return this.service.status(auth, id, jobId);
  }

  @Get(':id/magic-eraser/:jobId/preview')
  @FileResponse()
  @Authenticated({ permission: Permission.AssetEditGet })
  @Endpoint({
    summary: 'Get bounded Magic Eraser result preview',
    history: new HistoryBuilder().added('v1').beta('v1'),
  })
  async getMagicEraserPreview(
    @Auth() auth: AuthDto,
    @Param() { id, jobId }: MagicEraserJobParamsDto,
    @Res() res: Response,
    @Next() next: NextFunction,
  ) {
    await sendFile(res, next, () => this.service.preview(auth, id, jobId), this.logger);
  }

  @Delete(':id/magic-eraser/:jobId')
  @Authenticated({ permission: Permission.AssetEditGet })
  @Endpoint({ summary: 'Cancel or discard an editing session', history: new HistoryBuilder().added('v1').beta('v1') })
  cancelMagicEraserJob(
    @Auth() auth: AuthDto,
    @Param() { id, jobId }: MagicEraserJobParamsDto,
  ): Promise<MagicEraserJobResponseDto> {
    return this.service.cancel(auth, id, jobId);
  }

  @Post(':id/magic-eraser/:jobId/save')
  @Authenticated({ permission: Permission.AssetUpload })
  @Endpoint({
    summary: 'Save Magic Eraser result as a separate still asset',
    history: new HistoryBuilder().added('v1').beta('v1'),
  })
  saveMagicEraserCopy(
    @Auth() auth: AuthDto,
    @Param() { id, jobId }: MagicEraserJobParamsDto,
  ): Promise<AssetMediaResponseDto> {
    return this.service.save(auth, id, jobId);
  }
}
