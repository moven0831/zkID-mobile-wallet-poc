use crate::{paths::PathConfig, utils::*, Scalar, E};
use bellpepper_core::{num::AllocatedNum, ConstraintSystem, SynthesisError};
use circom_scotia::{reader::load_r1cs, synthesize};
use serde_json::Value;
use spartan2::traits::circuit::SpartanCircuit;
use std::{any::type_name, fs::File, path::PathBuf, time::Instant};
use tracing::info;

witnesscalc_adapter::witness!(show);

// show.circom
#[derive(Debug, Clone)]
pub struct ShowCircuit {
    /// Path configuration for resolving file paths
    path_config: PathConfig,
    /// Optional override for input JSON path
    input_path: Option<PathBuf>,
}

impl Default for ShowCircuit {
    fn default() -> Self {
        Self {
            path_config: PathConfig::default(),
            input_path: None,
        }
    }
}

impl ShowCircuit {
    /// Create a new ShowCircuit with PathConfig and optional input path override.
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
            .unwrap_or_else(|| self.path_config.input_json("show"))
    }

    /// Get the R1CS file path.
    fn r1cs_path(&self) -> PathBuf {
        self.path_config.r1cs_path("show")
    }

    fn load_inputs(&self) -> Result<Value, SynthesisError> {
        let path = self.resolve_input_json();
        info!("Loading show inputs from {}", path.display());
        let file = File::open(&path).map_err(|_| SynthesisError::AssignmentMissing)?;
        serde_json::from_reader(file).map_err(|_| SynthesisError::AssignmentMissing)
    }
}

impl SpartanCircuit<E> for ShowCircuit {
    fn synthesize<CS: ConstraintSystem<Scalar>>(
        &self,
        cs: &mut CS,
        _: &[AllocatedNum<Scalar>],
        _: &[AllocatedNum<Scalar>],
        _: Option<&[Scalar]>,
    ) -> Result<(), SynthesisError> {
        let r1cs_path = self.r1cs_path();
        let json_value = self.load_inputs()?;

        // Parse inputs using declarative field definitions
        let inputs = parse_show_inputs(&json_value)?;

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

        // Generate witness using witnesscalc
        info!("Generating witness using witnesscalc...");
        let t0 = Instant::now();

        let inputs_json = hashmap_to_json_string(&inputs)?;

        // Generate raw witness bytes
        let witness_bytes =
            show_witness(&inputs_json).map_err(|_| SynthesisError::Unsatisfiable)?;

        info!("witnesscalc time: {} ms", t0.elapsed().as_millis());

        // Parse witness bytes directly to Scalar
        let witness = parse_witness(&witness_bytes)?;

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
        let json_value = self.load_inputs()?;

        let inputs = parse_show_inputs(&json_value)?;
        let keybinding_x_bigint = inputs.get("deviceKeyX").unwrap()[0].clone();
        let keybinding_y_bigint = inputs.get("deviceKeyY").unwrap()[0].clone();
        let claim_bigints = inputs
            .get("claim")
            .cloned()
            .ok_or(SynthesisError::AssignmentMissing)?;

        let keybinding_x = bigint_to_scalar(keybinding_x_bigint)?;
        let keybinding_y = bigint_to_scalar(keybinding_y_bigint)?;
        let claim_scalars = convert_bigint_to_scalar(claim_bigints)?;

        let kb_x = AllocatedNum::alloc(cs.namespace(|| "KeyBindingX"), || Ok(keybinding_x))?;
        let kb_y = AllocatedNum::alloc(cs.namespace(|| "KeyBindingY"), || Ok(keybinding_y))?;

        let mut shared_values = Vec::with_capacity(2 + claim_scalars.len());
        shared_values.push(kb_x);
        shared_values.push(kb_y);

        for (idx, claim_scalar) in claim_scalars.into_iter().enumerate() {
            let claim_value = claim_scalar;
            let claim_alloc =
                AllocatedNum::alloc(cs.namespace(|| format!("Claim{idx}")), move || {
                    Ok(claim_value)
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
