#!/usr/bin/env bash
# ============================================================
# Create a custom persona using Big Five trait scores
# ============================================================
# Usage: ./create-persona.sh
# ============================================================

set -euo pipefail

AGENT_HOME="${CLU_HOME:-$HOME/.clu}"
PERSONAS_DIR="$AGENT_HOME/personas"

echo "╔══════════════════════════════════════════════╗"
echo "║       Create a Custom Persona (OCEAN)        ║"
echo "╚══════════════════════════════════════════════╝"
echo ""

# Name
read -p "Persona name (lowercase, no spaces): " NAME
if [[ -z "$NAME" || -f "$PERSONAS_DIR/$NAME.md" ]]; then
    [[ -f "$PERSONAS_DIR/$NAME.md" ]] && echo "❌ Persona '$NAME' already exists." && exit 1
    [[ -z "$NAME" ]] && echo "❌ Name required." && exit 1
fi

# Role
echo ""
read -p "Role description (one line): " ROLE

echo ""
echo "Score each trait from 1–10."
echo "Reference:"
echo "  O – Openness:          1=conventional ←→ 10=exploratory"
echo "  C – Conscientiousness: 1=fast & loose ←→ 10=meticulous"
echo "  E – Extraversion:      1=silent worker ←→ 10=highly verbal"
echo "  A – Agreeableness:     1=blunt critic  ←→ 10=accommodating"
echo "  N – Neuroticism:       1=fearless      ←→ 10=very cautious"
echo ""

read_score() {
    local label="$1" hint="$2"
    local score
    while true; do
        read -p "  $label ($hint) [1-10]: " score
        if [[ "$score" =~ ^[0-9]+$ ]] && (( score >= 1 && score <= 10 )); then
            echo "$score"
            return
        fi
        echo "    Please enter a number between 1 and 10."
    done
}

O=$(read_score "O – Openness" "conventional vs exploratory")
C=$(read_score "C – Conscientiousness" "loose vs meticulous")
E=$(read_score "E – Extraversion" "quiet vs talkative")
A=$(read_score "A – Agreeableness" "blunt vs accommodating")
N=$(read_score "N – Neuroticism" "bold vs cautious")

# Generate behavioral notes based on extreme scores
echo ""
echo "Optional: Add behavioral notes (Enter to skip, or type notes):"
read -p "  > " NOTES

# Build the file
OUTFILE="$PERSONAS_DIR/$NAME.md"

cat > "$OUTFILE" << EOF
# Persona: ${NAME^}

## Traits

\`\`\`yaml
openness:          $O
conscientiousness: $C
extraversion:      $E
agreeableness:     $A
neuroticism:       $N
\`\`\`

## Role
$ROLE
EOF

if [[ -n "$NOTES" ]]; then
    cat >> "$OUTFILE" << EOF

## Behavioral Notes
$NOTES
EOF
fi

echo ""
echo "✅ Created: $OUTFILE"
echo ""
echo "Trait profile: O:$O  C:$C  E:$E  A:$A  N:$N"
echo ""

# Quick behavioral summary
echo "Behavioral summary:"
(( O >= 7 )) && echo "  • Highly creative and exploratory"
(( O <= 3 )) && echo "  • Conservative and conventional"
(( C >= 7 )) && echo "  • Very thorough and structured"
(( C <= 3 )) && echo "  • Fast and informal"
(( E >= 7 )) && echo "  • Actively communicative, thinks out loud"
(( E <= 3 )) && echo "  • Quiet, lets work speak for itself"
(( A >= 7 )) && echo "  • Cooperative and supportive"
(( A <= 3 )) && echo "  • Blunt and challenging"
(( N >= 7 )) && echo "  • Very cautious, flags all risks"
(( N <= 3 )) && echo "  • Bold and confident, moves fast"
echo ""
echo "Add '$NAME' to a project's available_personas list to use it."
