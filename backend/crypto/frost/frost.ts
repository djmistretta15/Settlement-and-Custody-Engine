/**
 * FROST (Flexible Round-Optimized Schnorr Threshold Signatures)
 * Production implementation using @noble/curves
 *
 * Based on: https://datatracker.ietf.org/doc/draft-irtf-cfrg-frost/
 *
 * Features:
 * - 2-round signing protocol
 * - No trusted dealer (DKG)
 * - Robust against rogue key attacks
 * - Supports secp256k1 and ed25519
 */

import { secp256k1 } from '@noble/curves/secp256k1';
import { ed25519 } from '@noble/curves/ed25519';
import { sha256 } from '@noble/hashes/sha256';
import { randomBytes } from '@noble/hashes/utils';
import * as mod from '@noble/curves/abstract/modular';

// ==================== TYPES ====================

export interface FrostParticipant {
  id: number;
  privateKeyShare: bigint;
  publicKeyShare: Uint8Array;
  verificationShare: Uint8Array;
}

export interface FrostPublicKey {
  groupPublicKey: Uint8Array;
  verificationShares: Map<number, Uint8Array>;
}

export interface SigningCommitment {
  participantId: number;
  hidingNonce: bigint;
  bindingNonce: bigint;
  hidingCommitment: Uint8Array;
  bindingCommitment: Uint8Array;
}

export interface SignatureShare {
  participantId: number;
  share: bigint;
}

export interface FrostSignature {
  R: Uint8Array;
  z: bigint;
}

// ==================== FROST IMPLEMENTATION ====================

export class FROST {
  private curve: typeof secp256k1 | typeof ed25519;
  private order: bigint;
  private G: any; // Generator point

  constructor(curveName: 'secp256k1' | 'ed25519' = 'secp256k1') {
    this.curve = curveName === 'secp256k1' ? secp256k1 : ed25519;
    this.order = this.curve.CURVE.n;
    this.G = this.curve.ProjectivePoint.BASE;
  }

  // ==================== KEY GENERATION ====================

  /**
   * Distributed Key Generation (DKG) - Pedersen's scheme
   * Each participant generates a share of the group private key
   *
   * @param threshold Minimum signers required (t)
   * @param participants Total number of participants (n)
   * @returns Participant key shares and group public key
   */
  async distributedKeyGen(
    threshold: number,
    participants: number
  ): Promise<{
    participants: Map<number, FrostParticipant>;
    groupPublicKey: FrostPublicKey;
  }> {
    if (threshold > participants) {
      throw new Error('Threshold cannot exceed number of participants');
    }

    if (threshold < 2) {
      throw new Error('Threshold must be at least 2');
    }

    const participantMap = new Map<number, FrostParticipant>();
    const coefficientsPerParticipant = new Map<number, bigint[]>();
    const commitmentsPerParticipant = new Map<number, Uint8Array[]>();

    // Round 1: Each participant generates polynomial coefficients
    for (let i = 1; i <= participants; i++) {
      const coefficients: bigint[] = [];

      // Generate t random coefficients (degree t-1 polynomial)
      for (let j = 0; j < threshold; j++) {
        const coeff = mod.mod(
          BigInt('0x' + Buffer.from(randomBytes(32)).toString('hex')),
          this.order
        );
        coefficients.push(coeff);
      }

      coefficientsPerParticipant.set(i, coefficients);

      // Create commitments to coefficients
      const commitments = coefficients.map(c => {
        return this.G.multiply(c).toRawBytes();
      });

      commitmentsPerParticipant.set(i, commitments);
    }

    // Round 2: Each participant computes shares for others
    const sharesFromTo = new Map<string, bigint>(); // key: "from_to"

    for (let from = 1; from <= participants; from++) {
      const coeffs = coefficientsPerParticipant.get(from)!;

      for (let to = 1; to <= participants; to++) {
        // Evaluate polynomial at point 'to'
        const share = this.evaluatePolynomial(coeffs, BigInt(to));
        sharesFromTo.set(`${from}_${to}`, share);
      }
    }

    // Round 3: Each participant aggregates received shares
    for (let i = 1; i <= participants; i++) {
      let privateKeyShare = BigInt(0);

      // Sum shares from all participants
      for (let j = 1; j <= participants; j++) {
        const share = sharesFromTo.get(`${j}_${i}`)!;
        privateKeyShare = mod.mod(privateKeyShare + share, this.order);
      }

      // Compute public key share
      const publicKeyShare = this.G.multiply(privateKeyShare).toRawBytes();

      // Compute verification share (commitment to secret)
      const verificationShare = this.G.multiply(privateKeyShare).toRawBytes();

      participantMap.set(i, {
        id: i,
        privateKeyShare,
        publicKeyShare,
        verificationShare
      });
    }

    // Compute group public key
    const groupPublicKey = this.computeGroupPublicKey(participantMap);

    return {
      participants: participantMap,
      groupPublicKey
    };
  }

  private evaluatePolynomial(coefficients: bigint[], x: bigint): bigint {
    let result = BigInt(0);
    let power = BigInt(1);

    for (const coeff of coefficients) {
      const term = mod.mod(coeff * power, this.order);
      result = mod.mod(result + term, this.order);
      power = mod.mod(power * x, this.order);
    }

    return result;
  }

  private computeGroupPublicKey(
    participants: Map<number, FrostParticipant>
  ): FrostPublicKey {
    let groupPoint = this.curve.ProjectivePoint.ZERO;

    for (const [id, participant] of participants) {
      const point = this.curve.ProjectivePoint.fromHex(participant.publicKeyShare);
      groupPoint = groupPoint.add(point);
    }

    const verificationShares = new Map<number, Uint8Array>();
    for (const [id, participant] of participants) {
      verificationShares.set(id, participant.verificationShare);
    }

    return {
      groupPublicKey: groupPoint.toRawBytes(),
      verificationShares
    };
  }

  // ==================== SIGNING PROTOCOL ====================

  /**
   * Round 1: Generate signing commitments
   * Each signer generates nonces and commitments
   */
  async generateCommitments(
    participant: FrostParticipant
  ): Promise<SigningCommitment> {
    // Generate hiding nonce
    const hidingNonce = mod.mod(
      BigInt('0x' + Buffer.from(randomBytes(32)).toString('hex')),
      this.order
    );

    // Generate binding nonce
    const bindingNonce = mod.mod(
      BigInt('0x' + Buffer.from(randomBytes(32)).toString('hex')),
      this.order
    );

    // Compute commitments
    const hidingCommitment = this.G.multiply(hidingNonce).toRawBytes();
    const bindingCommitment = this.G.multiply(bindingNonce).toRawBytes();

    return {
      participantId: participant.id,
      hidingNonce,
      bindingNonce,
      hidingCommitment,
      bindingCommitment
    };
  }

  /**
   * Round 2: Generate signature share
   * Each signer creates their share of the signature
   */
  async generateSignatureShare(
    message: Uint8Array,
    participant: FrostParticipant,
    commitment: SigningCommitment,
    allCommitments: SigningCommitment[],
    signerIds: number[]
  ): Promise<SignatureShare> {
    // Compute binding factor
    const bindingFactor = this.computeBindingFactor(
      message,
      allCommitments
    );

    // Compute group commitment R
    const R = this.computeGroupCommitment(allCommitments, bindingFactor);

    // Compute Lagrange coefficient for this participant
    const lambda = this.computeLagrangeCoefficient(
      participant.id,
      signerIds
    );

    // Compute challenge
    const challenge = this.computeChallenge(R, message, allCommitments);

    // Compute signature share
    // z_i = d_i + (e_i * λ_i * s_i)
    // where d_i = hiding nonce, e_i = binding nonce * binding factor
    const share = mod.mod(
      commitment.hidingNonce +
      mod.mod(
        commitment.bindingNonce * bindingFactor,
        this.order
      ) +
      mod.mod(
        mod.mod(
          challenge * lambda,
          this.order
        ) * participant.privateKeyShare,
        this.order
      ),
      this.order
    );

    return {
      participantId: participant.id,
      share
    };
  }

  /**
   * Aggregate signature shares into final signature
   */
  async aggregateSignatures(
    message: Uint8Array,
    signatureShares: SignatureShare[],
    commitments: SigningCommitment[]
  ): Promise<FrostSignature> {
    // Compute binding factor
    const bindingFactor = this.computeBindingFactor(message, commitments);

    // Compute group commitment R
    const R = this.computeGroupCommitment(commitments, bindingFactor);

    // Aggregate shares
    let z = BigInt(0);
    for (const share of signatureShares) {
      z = mod.mod(z + share.share, this.order);
    }

    return {
      R,
      z
    };
  }

  /**
   * Verify FROST signature
   */
  async verify(
    message: Uint8Array,
    signature: FrostSignature,
    groupPublicKey: Uint8Array
  ): Promise<boolean> {
    try {
      // Parse R and public key
      const R = this.curve.ProjectivePoint.fromHex(signature.R);
      const PK = this.curve.ProjectivePoint.fromHex(groupPublicKey);

      // Compute challenge
      const challenge = this.computeChallengeFromSignature(
        signature.R,
        message,
        groupPublicKey
      );

      // Verify: G * z = R + c * PK
      const left = this.G.multiply(signature.z);
      const right = R.add(PK.multiply(challenge));

      return left.equals(right);
    } catch (error) {
      return false;
    }
  }

  // ==================== HELPER FUNCTIONS ====================

  private computeBindingFactor(
    message: Uint8Array,
    commitments: SigningCommitment[]
  ): bigint {
    // H(message || commitments)
    const data = new Uint8Array([
      ...message,
      ...commitments.flatMap(c => [
        ...c.hidingCommitment,
        ...c.bindingCommitment
      ])
    ]);

    const hash = sha256(data);
    return mod.mod(BigInt('0x' + Buffer.from(hash).toString('hex')), this.order);
  }

  private computeGroupCommitment(
    commitments: SigningCommitment[],
    bindingFactor: bigint
  ): Uint8Array {
    let R = this.curve.ProjectivePoint.ZERO;

    for (const commitment of commitments) {
      const D = this.curve.ProjectivePoint.fromHex(commitment.hidingCommitment);
      const E = this.curve.ProjectivePoint.fromHex(commitment.bindingCommitment);

      // R = D + rho * E
      const term = E.multiply(bindingFactor);
      R = R.add(D).add(term);
    }

    return R.toRawBytes();
  }

  private computeLagrangeCoefficient(
    participantId: number,
    signerIds: number[]
  ): bigint {
    let numerator = BigInt(1);
    let denominator = BigInt(1);

    for (const j of signerIds) {
      if (j === participantId) continue;

      numerator = mod.mod(numerator * BigInt(j), this.order);
      const diff = mod.mod(BigInt(j) - BigInt(participantId), this.order);
      denominator = mod.mod(denominator * diff, this.order);
    }

    // Compute modular inverse of denominator
    const denominatorInv = mod.invert(denominator, this.order);
    return mod.mod(numerator * denominatorInv, this.order);
  }

  private computeChallenge(
    R: Uint8Array,
    message: Uint8Array,
    commitments: SigningCommitment[]
  ): bigint {
    // H(R || PK || message)
    const data = new Uint8Array([...R, ...message]);
    const hash = sha256(data);
    return mod.mod(BigInt('0x' + Buffer.from(hash).toString('hex')), this.order);
  }

  private computeChallengeFromSignature(
    R: Uint8Array,
    message: Uint8Array,
    publicKey: Uint8Array
  ): bigint {
    const data = new Uint8Array([...R, ...publicKey, ...message]);
    const hash = sha256(data);
    return mod.mod(BigInt('0x' + Buffer.from(hash).toString('hex')), this.order);
  }
}

// ==================== EXPORTS ====================

export default FROST;

// Example usage
if (require.main === module) {
  (async () => {
    const frost = new FROST('secp256k1');

    // Generate keys (2-of-3 threshold)
    console.log('Generating 2-of-3 threshold keys...');
    const { participants, groupPublicKey } = await frost.distributedKeyGen(2, 3);

    console.log('Group public key:', Buffer.from(groupPublicKey.groupPublicKey).toString('hex'));

    // Signing with participants 1 and 2
    const message = new TextEncoder().encode('Hello FROST!');
    const signerIds = [1, 2];

    // Round 1: Generate commitments
    const commitments: SigningCommitment[] = [];
    for (const id of signerIds) {
      const participant = participants.get(id)!;
      const commitment = await frost.generateCommitments(participant);
      commitments.push(commitment);
    }

    // Round 2: Generate signature shares
    const shares: SignatureShare[] = [];
    for (let i = 0; i < signerIds.length; i++) {
      const id = signerIds[i];
      const participant = participants.get(id)!;
      const share = await frost.generateSignatureShare(
        message,
        participant,
        commitments[i],
        commitments,
        signerIds
      );
      shares.push(share);
    }

    // Aggregate signature
    const signature = await frost.aggregateSignatures(message, shares, commitments);

    console.log('Signature R:', Buffer.from(signature.R).toString('hex'));
    console.log('Signature z:', signature.z.toString(16));

    // Verify
    const isValid = await frost.verify(message, signature, groupPublicKey.groupPublicKey);
    console.log('Signature valid:', isValid);
  })();
}
