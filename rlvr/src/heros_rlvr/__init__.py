"""HEROS-RLVR: verifiable-reasoning post-training primitives."""

from .advantages import AdvantageConfig, dr_grpo_advantages, group_advantages
from .audit import (
    AuditRecord,
    MiracleStepResult,
    Step,
    detect_miracle_step,
    verifier_error_rates,
)
from .gpu_trainer import (
    TORCH_AVAILABLE,
    DapoDynamicSampler,
    DeterministicForgeShadowVerifier,
    MigrationTask,
    VerificationReceipt,
    compute_dr_grpo_token_loss,
)
from .losses import (
    LossConfig,
    LossResult,
    dapo_config,
    dr_grpo_config,
    grpo_config,
    grpo_loss,
)
from .qlora_runner import (
    HFPolicy,
    QLoRARunner,
    RolloutBatch,
    RunRecorder,
    RunnerConfig,
    StepResult,
    build_prompt,
    build_rollout_batch,
    dataset_row_to_task,
    load_dataset,
)
from .sampling import dynamic_sample, group_std, has_learning_signal, rejection_rate
from .trainer import Completion, Rollout, build_rollout
from .verifier import (
    CommandVerifier,
    VerificationResult,
    compose_reward,
    has_think_answer_format,
)

__all__ = [
    "AdvantageConfig",
    "AuditRecord",
    "CommandVerifier",
    "Completion",
    "DapoDynamicSampler",
    "DeterministicForgeShadowVerifier",
    "HFPolicy",
    "LossConfig",
    "LossResult",
    "MigrationTask",
    "MiracleStepResult",
    "QLoRARunner",
    "Rollout",
    "RolloutBatch",
    "RunRecorder",
    "RunnerConfig",
    "Step",
    "StepResult",
    "TORCH_AVAILABLE",
    "VerificationReceipt",
    "VerificationResult",
    "build_prompt",
    "build_rollout",
    "build_rollout_batch",
    "compose_reward",
    "compute_dr_grpo_token_loss",
    "dapo_config",
    "dataset_row_to_task",
    "detect_miracle_step",
    "dr_grpo_advantages",
    "dr_grpo_config",
    "dynamic_sample",
    "group_advantages",
    "group_std",
    "grpo_config",
    "grpo_loss",
    "has_learning_signal",
    "has_think_answer_format",
    "load_dataset",
    "rejection_rate",
    "verifier_error_rates",
]
