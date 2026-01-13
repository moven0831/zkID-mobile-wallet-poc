use crate::{
    paths::PathConfig,
    prover::generate_prepare_witness,
    utils::{compute_prepare_shared_scalars, PrepareSharedScalars},
    Scalar, E,
};
use bellpepper_core::{num::AllocatedNum, ConstraintSystem, SynthesisError};
use circom_scotia::{reader::load_r1cs, synthesize};
use serde_json::Value;
use spartan2::traits::circuit::SpartanCircuit;
use std::{any::type_name, fs::File, path::PathBuf};

witnesscalc_adapter::witness!(jwt);

// jwt.circom
#[derive(Debug, Clone)]
pub struct PrepareCircuit {
    /// Path configuration for resolving file paths
    path_config: PathConfig,
    /// Optional override for input JSON path
    input_path: Option<PathBuf>,
}

impl Default for PrepareCircuit {
    fn default() -> Self {
        Self {
            path_config: PathConfig::default(),
            input_path: None,
        }
    }
}

impl PrepareCircuit {
    /// Create a new PrepareCircuit with PathConfig and optional input path override.
    pub fn new(path_config: PathConfig, input_path: Option<PathBuf>) -> Self {
        Self {
            path_config,
            input_path,
        }
    }

    /// Create from just an input path (for backwards compatibility).
    /// Uses development PathConfig.
    pub fn with_input_path<P: Into<Option<PathBuf>>>(path: P) -> Self {
        Self {
            path_config: PathConfig::development(),
            input_path: path.into(),
        }
    }

    /// Resolve the input JSON path using PathConfig.
    fn resolve_input_json(&self) -> PathBuf {
        self.input_path
            .as_ref()
            .map(|p| self.path_config.resolve(p))
            .unwrap_or_else(|| self.path_config.input_json("jwt"))
    }

    /// Get the R1CS file path.
    fn r1cs_path(&self) -> PathBuf {
        self.path_config.r1cs_path("jwt")
    }
}

impl SpartanCircuit<E> for PrepareCircuit {
    fn synthesize<CS: ConstraintSystem<Scalar>>(
        &self,
        cs: &mut CS,
        _: &[AllocatedNum<Scalar>],
        _: &[AllocatedNum<Scalar>],
        _: Option<&[Scalar]>,
    ) -> Result<(), SynthesisError> {
        let r1cs_path = self.r1cs_path();

        // Detect if we're in setup phase (ShapeCS) or prove phase (SatisfyingAssignment)
        // During setup, we only need constraint structure instead of actual witness values
        let cs_type = type_name::<CS>();
        let is_setup_phase = cs_type.contains("ShapeCS");

        if is_setup_phase {
            let r1cs = load_r1cs(&r1cs_path);
            // Pass None for witness during setup
            synthesize(cs, r1cs, None)?;
            return Ok(());
        }

        // Generate witness using the dedicated function
        let witness = generate_prepare_witness(
            &self.path_config,
            self.input_path.as_ref().map(|p| p.as_path()),
        )?;

        let r1cs = load_r1cs(&r1cs_path);
        synthesize(cs, r1cs, Some(witness))?;
        Ok(())
    }

    fn public_values(&self) -> Result<Vec<Scalar>, SynthesisError> {
        Ok(vec![])
    }
    fn shared<CS: ConstraintSystem<Scalar>>(
        &self,
        cs: &mut CS,
    ) -> Result<Vec<AllocatedNum<Scalar>>, SynthesisError> {
        let json_path = self.resolve_input_json();

        let json_file = File::open(&json_path).map_err(|_| SynthesisError::AssignmentMissing)?;

        let json_value: Value =
            serde_json::from_reader(json_file).map_err(|_| SynthesisError::AssignmentMissing)?;

        let PrepareSharedScalars {
            keybinding_x,
            keybinding_y,
            claim_scalars,
        } = compute_prepare_shared_scalars(&json_value)?;

        let keybinding_x_alloc =
            AllocatedNum::alloc(cs.namespace(|| "KeyBindingX"), || Ok(keybinding_x))?;
        let keybinding_y_alloc =
            AllocatedNum::alloc(cs.namespace(|| "KeyBindingY"), || Ok(keybinding_y))?;

        let mut shared_values = Vec::with_capacity(2 + claim_scalars.len());
        shared_values.push(keybinding_x_alloc);
        shared_values.push(keybinding_y_alloc);

        for (idx, claim_scalar) in claim_scalars.into_iter().enumerate() {
            let claim_alloc =
                AllocatedNum::alloc(cs.namespace(|| format!("Claim{idx}")), move || {
                    Ok(claim_scalar)
                })?;
            shared_values.push(claim_alloc);
        }

        Ok(shared_values)
    }
    fn precommitted<CS: ConstraintSystem<Scalar>>(
        &self,
        _cs: &mut CS,
        _shared: &[AllocatedNum<Scalar>],
    ) -> Result<Vec<AllocatedNum<Scalar>>, SynthesisError> {
        Ok(vec![])
    }
    fn num_challenges(&self) -> usize {
        0
    }
}
